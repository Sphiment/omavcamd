import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// State machine over bin/omavcam. Capture and system state come from the CLI;
// the one deliberate QML-owned system surface is the QtMultimedia overlay.
Item {
  id: root

  // Omarchy creates service entry points once and injects the shell object.
  // Read this plugin's bar settings directly so every per-screen bar widget
  // talks to the same capture state machine and the same overlay.
  property var shell: null
  property var manifest: null
  readonly property string pluginId: manifest && manifest.id
                                   ? String(manifest.id) : "sphiment.omavcam"
  readonly property var settings: settingsForPlugin()

  // Absolute path to our own bin/omavcam. A plugin directory is not on PATH,
  // so the service resolves the CLI beside this file.
  property string cli: String(Qt.resolvedUrl("bin/omavcam")).replace(/^file:\/\//, "")

  // ---- observed state -----------------------------------------------------
  property bool ready: false            // doctor reports nothing blocking
  property var issues: []
  property var missingPackages: []
  property var devices: []
  property var cameras: []
  property bool running: false          // a scrcpy process of ours is alive
  property bool streaming: false        // the node is actually advertising capture
  property var capture: ({})
  property int uptimeSec: 0
  property bool camerasLoaded: false
  property bool camerasDeferred: false
  property bool cameraRefreshRequested: false
  property bool initialStatusLoaded: false
  property bool windowPreviewOpen: false
  property bool overlayPreviewOpen: false
  // True while a setting change is being applied to a live stream.
  property bool reapplying: false
  readonly property string previewSize: String(setting("previewSize", "small"))
  // What "original" would produce on the monitor the preview would land on.
  // null until a stream exists to measure.
  property var windowPreviewOriginal: null
  property var overlayPreviewOriginal: null
  property string lastError: ""
  property bool checkedOnce: false

  // Optimistic state so the bar reacts the instant it is clicked rather than
  // at the next poll. -1 means "just follow what was observed".
  property int _desired: -1
  readonly property bool active: _desired === -1 ? streaming : (_desired === 1)

  readonly property bool busy: actionProcess.running || setupWatch.running || previewProcess.running
  readonly property string previewSource: String(setting("previewSource", "loopback"))
  readonly property string previewSurface: String(setting("previewSurface", "overlay"))
  readonly property bool overlayMode: previewSource === "loopback" && previewSurface === "overlay"
  readonly property bool previewOpen: overlayMode ? overlayPreviewOpen : windowPreviewOpen
  // Migrate both older shapes lazily. A boolean meant none/all; levels were
  // cumulative (edges, then corners, then centre). As soon as the checklist is
  // changed, all three explicit booleans are persisted together.
  readonly property int legacySnapLevel: normalizedSnapLevel(
                                           setting("previewSnapLevel",
                                                   setting("previewSnap", 3)))
  readonly property bool previewSnapEdges: normalizedSnapFlag(
                                             setting("previewSnapEdges", legacySnapLevel >= 1))
  readonly property bool previewSnapCorners: normalizedSnapFlag(
                                               setting("previewSnapCorners", legacySnapLevel >= 2))
  readonly property bool previewSnapCenter: normalizedSnapFlag(
                                              setting("previewSnapCenter", legacySnapLevel >= 3))
  readonly property bool previewSnap: previewSnapEdges || previewSnapCorners || previewSnapCenter
  readonly property var previewOriginal: overlayMode ? overlayPreviewOriginal : windowPreviewOriginal
  readonly property var device: Model.selectedDevice(devices, setting("serial", ""))
  readonly property bool hasDevice: !!device
  readonly property var effectiveCamera: Model.effectiveCamera(cameras, setting("facing", "front"), setting("cameraId", ""))
  readonly property var sizeOptions: Model.sizeOptions(cameras, setting("facing", "front"), setting("cameraId", ""))
  readonly property var blockingIssue: Model.blockingIssue(issues)
  readonly property bool needsInstall: (missingPackages || []).length > 0

  // An overlay is allowed to exist only for a live capture owned by this
  // service, writing to the exact node doctor verified as omavcam. `streaming`
  // alone is intentionally insufficient: another producer could make a V4L2
  // node advertise capture without being our scrcpy process.
  property string loopbackDevicePath: ""
  property string loopbackDeviceLabel: ""
  property bool loopbackDeviceOwned: false
  property bool multimediaAvailable: false
  readonly property bool overlayCaptureReady: overlayPreviewOpen
                                                   && overlayMode
                                                   && running
                                                   && streaming
                                                   && !reapplying
                                                   && loopbackDeviceOwned
                                                   && String(capture.device || "") === loopbackDevicePath

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 5)), 10)
    if (!isFinite(n)) n = 5
    return Math.max(2, Math.min(120, n))
  }

  signal captureFailed(string message)

  onOverlayModeChanged: if (!overlayMode) overlayPreviewOpen = false
  onStreamingChanged: {
    if (!streaming && !reapplying) overlayPreviewOpen = false
    if (!streaming && camerasDeferred) {
      camerasDeferred = false
      camerasLoaded = false
      cameraRefreshRequested = true
      cameraRefreshDelay.restart()
    }
  }
  onRunningChanged: {
    if (!running && !reapplying) overlayPreviewOpen = false
  }

  function settingsForPlugin() {
    var config = shell ? shell.shellConfig : null
    var layout = config && config.bar ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var s = 0; layout && s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && String(entries[i].id || "") === pluginId) return entries[i]
      }
    }
    var plugins = config && Array.isArray(config.plugins) ? config.plugins : []
    for (var p = 0; p < plugins.length; p++) {
      if (plugins[p] && String(plugins[p].id || "") === pluginId) return plugins[p]
    }
    return ({})
  }

  function persist(values) {
    if (!shell || typeof shell.updateEntryInline !== "function") return
    var entry = { id: pluginId }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    for (var name in values) entry[name] = values[name]
    shell.updateEntryInline(pluginId, entry)
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function statusText() {
    if (!checkedOnce) return "Checking…"
    if (needsInstall) return "Dependencies missing"
    if (blockingIssue && !streaming) return "Not ready"
    if (reapplying) return "Applying…"
    if (streaming) {
      var label = Model.formatUptime(uptimeSec)
      return label === "" ? "Streaming" : "Streaming · " + label
    }
    if (running) return "Starting…"
    if (!hasDevice) return "No phone"
    return "Ready"
  }

  // ---- reading state ------------------------------------------------------

  function normalizedSnapLevel(value) {
    var word = String(value).toLowerCase()
    if (value === true || word === "true" || word === "on") return 3
    if (value === false || word === "false" || word === "off") return 0
    var level = parseInt(word, 10)
    if (!isFinite(level)) level = 3
    return Math.max(0, Math.min(3, level))
  }

  function normalizedSnapFlag(value) {
    var word = String(value).toLowerCase()
    return value === true || word === "true" || word === "on" || word === "1"
  }

  // The CLI window preview still has one on/off magnet. Any checked target
  // group enables it, while the overlay itself gets the exact checklist. The
  // environment beats the CLI's saved preference, which makes the panel's
  // choices the ones that count.
  function withSource(args, source, snap) {
    var enabled = snap === undefined ? previewSnap : normalizedSnapFlag(snap)
    return ["env",
            "OMAVCAM_PREVIEW_SOURCE=" + (source || previewSource),
            "OMAVCAM_PREVIEW_SNAP=" + (enabled ? "on" : "off")].concat(args)
  }

  // scrcpy fixes the camera, resolution and frame rate at launch, so a setting
  // cannot be changed on a live stream — it can only be re-established on a new
  // one. restart carries the settings across, and omavcam does it for the user
  // rather than making them stop and start by hand.
  //
  // Every managed value is sent explicitly, including empty ones, because empty
  // is a real choice ("camera default") and must be distinguishable from
  // "unspecified", which restart takes to mean "leave alone".
  function restartArgs(overrides) {
    var o = overrides || {}
    function pick(key, fallback) {
      return o[key] !== undefined ? String(o[key]) : String(setting(key, fallback))
    }

    var args = []
    if (device) args.push("-s", String(device.serial))

    var cameraId = pick("cameraId", "")
    if (cameraId !== "") args.push("--camera-id", cameraId)
    else args.push("--facing", pick("facing", "front"))

    args.push("--size", pick("size", ""))
    args.push("--fps", pick("fps", ""))
    return args
  }

  // Applies a setting to a running capture. Does nothing when idle — the new
  // value is already persisted and will be used by the next start.
  function applyLive(overrides) {
    if (cli === "" || actionProcess.running) return
    if (!running && !streaming) return
    reapplying = true
    _desired = 1
    lastError = ""
    actionProcess.command = withSource([cli, "restart"].concat(restartArgs(overrides)))
    actionProcess.running = true
  }

  function runPreviewAction(action, source, afterAction) {
    if (cli === "" || previewProcess.running) return false
    previewProcess.afterAction = afterAction || ""
    previewProcess.command = withSource([cli, "preview", action], source)
    previewProcess.running = true
    return true
  }

  function resizeWindowPreview() {
    if (cli === "" || previewProcess.running || !windowPreviewOpen) return
    previewProcess.afterAction = ""
    previewProcess.command = withSource([cli, "preview", "resize", previewSize])
    previewProcess.running = true
  }

  // Preserve an open preview while its source or surface changes. scrcpy and
  // mpv remain CLI-owned windows; only the virtual-cam source can move into the
  // plugin overlay.
  function changePreviewMode(source, surface) {
    var nextSource = String(source || previewSource)
    var nextSurface = String(surface || previewSurface)
    var wasOpen = previewOpen
    var wasOverlay = overlayMode
    var nextOverlay = nextSource === "loopback" && nextSurface === "overlay"

    persist({ previewSource: nextSource, previewSurface: nextSurface })
    if (!wasOpen) return

    if (wasOverlay) {
      if (nextOverlay) return
      overlayPreviewOpen = false
      runPreviewAction("on", nextSource, "resize-window")
      return
    }

    if (nextOverlay) {
      runPreviewAction("off", previewSource, "open-overlay")
    } else {
      runPreviewAction("reopen", nextSource, "resize-window")
    }
  }

  function refresh() {
    if (cli === "") return
    if (!doctorProcess.running) {
      doctorProcess.command = [cli, "doctor", "--json"]
      doctorProcess.running = true
    }
    refreshStatus()
    if (!devicesProcess.running) {
      devicesProcess.command = [cli, "devices", "--json"]
      devicesProcess.running = true
    }
  }

  function refreshStatus() {
    if (cli === "" || statusProcess.running) return
    statusProcess.command = withSource([cli, "status", "--json"])
    statusProcess.running = true
  }

  // Deliberately not part of refresh(): listing cameras pushes scrcpy's server
  // to the phone, so it runs when the panel opens or the phone changes, not on
  // every poll.
  function maybeRefreshCameras() {
    if (!cameraRefreshRequested || cli === "" || !hasDevice
        || !initialStatusLoaded || camerasProcess.running
        || cameraRefreshDelay.running) return

    // Never ask scrcpy to open the phone camera merely to populate a menu while
    // the capture owns it. More importantly, do not leave the panel claiming it
    // is still "Reading…" for the entire stream: mark the optional details as
    // deferred and refresh them after capture stops.
    if (actionProcess.running || reapplying || running || streaming) {
      camerasDeferred = true
      camerasLoaded = true
      return
    }

    camerasDeferred = false
    camerasProcess.command = [cli, "cameras", "--json", "-s", String(device.serial)]
    camerasProcess.running = true
  }

  function refreshCameras() {
    // A panel can open before the first `devices` and `status` processes have
    // returned. Remember the request instead of dropping it in that gap.
    cameraRefreshRequested = true
    maybeRefreshCameras()
  }

  // ---- acting -------------------------------------------------------------

  function start() {
    if (cli === "" || actionProcess.running) return
    _desired = 1
    lastError = ""

    var args = [cli, "start"]
    if (device) args.push("-s", String(device.serial))

    var cameraId = String(setting("cameraId", ""))
    if (cameraId !== "") args.push("--camera-id", cameraId)
    else args.push("--facing", String(setting("facing", "front")))

    var size = String(setting("size", ""))
    if (size !== "") args.push("--size", size)

    var fps = String(setting("fps", ""))
    if (fps !== "") args.push("--fps", fps)

    actionProcess.command = args
    actionProcess.running = true
  }

  function stop() {
    if (cli === "" || actionProcess.running) return
    // Match both existing preview modes: stopping omavcam closes the preview,
    // and a later start never resurrects it implicitly.
    overlayPreviewOpen = false
    _desired = 0
    actionProcess.command = [cli, "stop"]
    actionProcess.running = true
  }

  function toggle() {
    if (active) stop()
    else start()
  }

  function togglePreview() {
    if (previewProcess.running) return
    if (overlayMode) {
      if (!running || !streaming || !loopbackDeviceOwned
          || String(capture.device || "") !== loopbackDevicePath) return
      overlayPreviewOpen = !overlayPreviewOpen
      return
    }
    runPreviewAction(previewOpen ? "off" : "on", previewSource,
                     previewOpen ? "" : "resize-window")
  }

  // The new value is passed explicitly rather than read back from settings:
  // persisting it and running this happen in the same breath, and the setting
  // would still be the old one.
  function setPreviewSnapTargets(edges, corners, center) {
    var any = edges || corners || center
    persist({ previewSnapEdges: edges === true,
              previewSnapCorners: corners === true,
              previewSnapCenter: center === true })
    if (overlayMode || cli === "" || previewProcess.running) return
    previewProcess.afterAction = ""
    previewProcess.command = withSource([cli, "preview", "snap", any ? "on" : "off"], "", any)
    previewProcess.running = true
  }

  function setPreviewSnapTarget(name, enabled) {
    var edges = previewSnapEdges
    var corners = previewSnapCorners
    var center = previewSnapCenter
    if (name === "edges") edges = enabled
    else if (name === "corners") corners = enabled
    else if (name === "center") center = enabled
    else return
    setPreviewSnapTargets(edges, corners, center)
  }

  // Compatibility for the short-lived numeric-level API.
  function setPreviewSnapLevel(level) {
    var next = normalizedSnapLevel(level)
    setPreviewSnapTargets(next >= 1, next >= 2, next >= 3)
  }

  // Compatibility for callers using the old boolean API.
  function setPreviewSnap(enabled) {
    setPreviewSnapTargets(enabled, enabled, enabled)
  }

  function setPreviewSize(size) {
    persist({ previewSize: size })
    if (overlayMode || cli === "" || previewProcess.running || !windowPreviewOpen) return
    previewProcess.afterAction = ""
    previewProcess.command = withSource([cli, "preview", "resize", size])
    previewProcess.running = true
  }

  // Package installation needs a terminal: it prompts for sudo and its output
  // is worth watching. Omarchy already owns that surface, so hand off to it
  // rather than trying to render a pacman run inside a popup.
  function runSetup() {
    if (cli === "") return
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             cli + " setup"])
    setupWatch.restart()
  }

  Component.onCompleted: refresh()

  onCliChanged: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.cli !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // The general panel heartbeat is intentionally relaxed, but an on-screen
  // overlay must disappear promptly if the capture is stopped from a terminal
  // or crashes outside this service's action process.
  Timer {
    interval: 1000
    running: root.overlayPreviewOpen
    repeat: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: cameraRefreshDelay
    interval: 600
    repeat: false
    onTriggered: root.maybeRefreshCameras()
  }

  // Load the QtMultimedia file only after doctor confirms its package. If it is
  // missing, Service.qml still loads, reports the dependency, and can launch
  // setup instead of disappearing along with the whole bar widget.
  Loader {
    id: overlayLoader
    active: root.multimediaAvailable
    source: active ? Qt.resolvedUrl("Overlay.qml") : ""
    onItemChanged: {
      root.overlayPreviewOriginal = item ? item["originalInfo"] : null
    }
  }

  Binding {
    target: overlayLoader.item
    property: "previewActive"
    value: root.overlayCaptureReady
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "snapEdges"
    value: root.previewSnapEdges
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "snapCorners"
    value: root.previewSnapCorners
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "snapCenter"
    value: root.previewSnapCenter
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "sizeName"
    value: root.previewSize
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "savedAnchor"
    value: String(root.setting("previewAnchor", "bottom-right"))
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "savedScreen"
    value: String(root.setting("previewScreen", ""))
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "devicePath"
    value: root.loopbackDevicePath
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "deviceLabel"
    value: root.loopbackDeviceLabel || "omavcam"
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "nativeWidth"
    value: root.windowPreviewOriginal ? parseInt(root.windowPreviewOriginal.width, 10) || 0 : 0
    when: !!overlayLoader.item
  }
  Binding {
    target: overlayLoader.item
    property: "nativeHeight"
    value: root.windowPreviewOriginal ? parseInt(root.windowPreviewOriginal.height, 10) || 0 : 0
    when: !!overlayLoader.item
  }

  Connections {
    target: overlayLoader.item
    function onOriginalInfoChanged() {
      root.overlayPreviewOriginal = overlayLoader.item
                                    ? overlayLoader.item["originalInfo"] : null
    }
    function onPlacementCommitted(screenName, anchor) {
      var values = { previewScreen: screenName }
      if (anchor !== "") values.previewAnchor = anchor
      root.persist(values)
    }
    function onCameraError(message) {
      root.lastError = "Overlay preview: " + message
    }
  }

  // A setup run happens in another window, so poll faster for a while after
  // launching it — otherwise the panel keeps claiming dependencies are missing
  // for several seconds after they are not.
  Timer {
    id: setupWatch
    interval: 2000
    repeat: true
    triggeredOnStart: false
    property int ticks: 0
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks > 150 || (root.ready && !root.needsInstall)) stop()
    }
    function restart() {
      ticks = 0
      start()
    }
  }

  Process {
    id: doctorProcess
    running: false
    command: []
    stdout: StdioCollector { id: doctorOut; waitForEnd: true }
    onExited: function (exitCode) {
      var report = Model.safeParse(doctorOut.text, null)
      root.checkedOnce = true
      if (!report) {
        root.ready = false
        return
      }
      root.ready = report.ok === true
      root.issues = report.issues || []
      root.missingPackages = report.missingPackages || []
      var mediaInstalled = false
      var packages = report.packages || []
      for (var i = 0; i < packages.length; i++) {
        if (String(packages[i].name || "") === "qt6-multimedia") {
          mediaInstalled = packages[i].installed === true
          break
        }
      }
      // Assign once. Toggling false/true on every doctor poll destroys and
      // recreates Overlay.qml, including its IPC handler and camera objects.
      root.multimediaAvailable = mediaInstalled
      var device = report.device || ({})
      root.loopbackDevicePath = String(device.path || "")
      root.loopbackDeviceLabel = String(device.label || "")
      root.loopbackDeviceOwned = device.present === true
                                  && root.loopbackDevicePath !== ""
                                  && root.loopbackDeviceLabel === "omavcam"
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function (exitCode) {
      var report = Model.safeParse(statusOut.text, null)
      if (!report) return
      root.initialStatusLoaded = true
      root.running = report.running === true
      root.streaming = report.streaming === true
      root.capture = report.capture || ({})
      root.uptimeSec = parseInt(report.uptimeSec, 10) || 0
      if (report.preview) {
        root.windowPreviewOpen = report.preview.open === true
        root.windowPreviewOriginal = report.preview.original || null
      }
      // Observation has caught up with the click, so stop overriding it.
      if (root._desired !== -1 && (root._desired === 1) === root.streaming) root._desired = -1
      root.maybeRefreshCameras()
    }
  }

  Process {
    id: devicesProcess
    running: false
    command: []
    stdout: StdioCollector { id: devicesOut; waitForEnd: true }
    onExited: function (exitCode) {
      var previous = root.device ? String(root.device.serial) : ""
      root.devices = Model.safeParse(devicesOut.text, [])
      var current = root.device ? String(root.device.serial) : ""
      // Cameras belong to a phone, so a different phone invalidates them.
      if (current !== previous) {
        root.cameras = []
        root.camerasLoaded = false
        root.camerasDeferred = false
        // Preload once per connected phone. This finishes in the background
        // before the panel is usually opened, making the camera section instant.
        root.cameraRefreshRequested = current !== ""
      }
      root.maybeRefreshCameras()
    }
  }

  Process {
    id: camerasProcess
    running: false
    command: []
    stdout: StdioCollector { id: camerasOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.cameras = Model.safeParse(camerasOut.text, [])
      root.camerasLoaded = true
      root.camerasDeferred = false
      root.cameraRefreshRequested = false
    }
  }

  Process {
    id: previewProcess
    property string afterAction: ""
    running: false
    command: []
    stdout: StdioCollector { id: previewOut; waitForEnd: true }
    stderr: StdioCollector { id: previewErr; waitForEnd: true }
    onExited: function (exitCode) {
      var continuation = afterAction
      afterAction = ""
      if (exitCode !== 0) {
        var text = String(previewErr.text || "").trim()
        if (text !== "") root.lastError = text.split("\n").pop()
      } else if (continuation === "open-overlay") {
        root.windowPreviewOpen = false
        root.overlayPreviewOpen = root.running && root.streaming
      } else if (continuation === "resize-window") {
        root.windowPreviewOpen = true
        Qt.callLater(root.resizeWindowPreview)
      }
      root.refresh()
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function (exitCode) {
      root.reapplying = false
      if (exitCode !== 0) {
        // start already prints scrcpy's own words on failure; surface the last
        // meaningful line rather than inventing a message.
        var text = String(actionErr.text || actionOut.text || "").trim()
        var lines = text.split("\n").filter(function (l) { return l.trim() !== "" })
        root.lastError = lines.length > 0 ? lines[lines.length - 1] : "Capture failed"
        root._desired = -1
        root.captureFailed(root.lastError)
      }
      root.refresh()
    }
  }
}
