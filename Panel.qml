import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "sphiment.omavcam"
  ipcTarget: "sphiment.omavcam"
  // manageIpc: false so this panel owns the single handler the target allows,
  // and can expose start/stop/toggleCapture for keybinds.
  manageIpc: false

  // The bar sizes a widget from its implicit size, and Panel is a bare Item —
  // without this the widget occupies zero width and renders nothing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The bar object is injected just after Loader finishes constructing this
  // item. Keep bindings quiet during that short gap; no action can reach this
  // object before the real singleton replaces it.
  QtObject {
    id: unavailableService
    readonly property bool active: false
    readonly property bool blockingIssue: false
    readonly property bool busy: false
    readonly property var cameras: []
    readonly property bool camerasLoaded: false
    readonly property bool camerasDeferred: false
    readonly property var devices: []
    readonly property bool hasDevice: false
    readonly property string lastError: ""
    readonly property var missingPackages: []
    readonly property bool needsInstall: false
    readonly property bool previewOpen: false
    readonly property var previewOriginal: null
    readonly property string previewSize: "small"
    readonly property bool previewSnapEdges: true
    readonly property bool previewSnapCorners: true
    readonly property bool previewSnapCenter: true
    readonly property bool previewSnap: true
    readonly property string previewSource: "loopback"
    readonly property string previewSurface: "overlay"
    readonly property var sizeOptions: []
    readonly property bool running: false
    readonly property bool streaming: false
    signal captureFailed(string message)
    function setting(name, fallback) { return fallback }
    function statusText() { return "Checking…" }
    function applyLive(overrides) {}
    function changePreviewMode(source, surface) {}
    function refresh() {}
    function refreshCameras() {}
    function runSetup() {}
    function setPreviewSize(size) {}
    function setPreviewSnapTargets(edges, corners, center) {}
    function setPreviewSnapTarget(name, enabled) {}
    function setPreviewSnapLevel(level) {}
    function setPreviewSnap(enabled) {}
    function start() {}
    function stop() {}
    function toggle() {}
    function togglePreview() {}
  }

  // The plugin service is loaded once by Omarchy and shared by every bar on
  // every screen. Keeping it out of this per-screen widget is what guarantees
  // one Qt camera reader and one set of overlay surfaces.
  readonly property var service: bar && bar.shell
                               ? (bar.shell.serviceFor(root.moduleName) || unavailableService)
                               : unavailableService

  // nf-md-webcam, from the same Material Design set every neighbouring widget
  // draws from. That matters for more than taste: OpticalGlyph renders at a
  // fixed point size and only corrects centring — it does not scale glyphs to a
  // common size — so a glyph's apparent size is whatever the font draws. In
  // JetBrainsMono Nerd Font the Font Awesome camera used here previously inks
  // 91 units tall against 109 for the monitor and bluetooth icons beside it,
  // which is why it read as undersized in the bar. This one inks 109, matching
  // them. State is carried by color, not by glyph.
  //
  // Written as an escape on purpose: as a literal character it is invisible in
  // a diff and survives nothing — an editor, a rewrite, or a stray encoding
  // step can drop it, leaving an empty string. BarIconButton hides a button
  // with no text, so losing it removes the widget from the bar silently, with
  // no error anywhere.
  //
  // Built from its code point rather than written as a character or a \u
  // escape: U+F05A0 sits above the BMP, so a \u escape cannot express it (those
  // take exactly four hex digits, and "\uf05a0" is the wrong glyph followed by
  // a stray "0").
  readonly property string icon: String.fromCodePoint(0xf05a0)

  readonly property color barIconColor: {
    if (service.active) return barForeground
    if (service.needsInstall || service.lastError !== "") return urgent
    return Qt.darker(barForeground, 1.55)
  }

  // A phone that is not plugged in is not a problem worth a bar icon, for
  // people who only occasionally use one.
  readonly property bool concealed: service.setting("hideWhenIdle", false) === true
                                    && !service.hasDevice && !service.active

  property bool cursorActive: false

  // An explicit camera id would override the facing the user just picked, so
  // choosing a facing clears it.
  function chooseFacing(facing) {
    // No camera re-listing here: the list belongs to the phone, not to the
    // facing, and sizeOptions is already derived from it. Asking for it now
    // would open the camera on the phone at the same moment scrcpy is trying
    // to claim it for the restart, and the capture loses that race.
    var change = {cameraId: "", facing: facing}

    // Carry the resolution over only if the camera being switched to actually
    // offers it. Otherwise scrcpy refuses the size and the stream drops for a
    // beat before the CLI's fallback rescues it — better to not ask.
    if (!Model.sizeSupported(service.cameras, facing, "", service.setting("size", ""))) {
      change.size = ""
    }

    persist(change)
    service.applyLive(change)
  }

  readonly property var previewSizes: ["small", "medium", "large", "original"]

  property bool originalWarningOpen: false

  // Only warn when the stream is known to be larger than the screen it would
  // open on. A measurement we could not take is not a reason to warn, and a
  // stream that fits should apply without ceremony.
  readonly property bool originalOverflows: {
    var o = service.previewOriginal
    return !!o && o.fitsScreen === false
  }

  readonly property string originalWarningText: {
    var o = service.previewOriginal
    if (!o) return ""
    return "The preview would be " + o.width + "\u00d7" + o.height
         + ", larger than this screen (" + o.screenWidth + "\u00d7" + o.screenHeight
         + "). The part outside the screen will be clipped."
  }

  // Applies a preview size, asking first when "original" would overflow.
  function choosePreviewSize(size) {
    if (size === "original" && originalOverflows) {
      originalWarningOpen = true
      return
    }
    service.setPreviewSize(size)
  }

  function togglePreviewSnap() {
    var all = service.previewSnapEdges && service.previewSnapCorners && service.previewSnapCenter
    service.setPreviewSnapTargets(!all, !all, !all)
  }

  function toggleSnapTarget(name) {
    if (name === "edges") service.setPreviewSnapTarget(name, !service.previewSnapEdges)
    else if (name === "corners") service.setPreviewSnapTarget(name, !service.previewSnapCorners)
    else if (name === "center") service.setPreviewSnapTarget(name, !service.previewSnapCenter)
  }

  function nextPreviewSize(step) {
    var index = previewSizes.indexOf(service.previewSize)
    if (index === -1) index = 1
    return previewSizes[Math.max(0, Math.min(previewSizes.length - 1, index + step))]
  }

  // Takes a whole set of values, because writing them one at a time would read
  // back a stale `settings` for the second key and undo the first.
  function persist(values) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = {id: root.moduleName}
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    for (var key in values) entry[key] = values[key]
    bar.shell.updateEntryInline(root.moduleName, entry)
  }

  Connections {
    target: root.service
    function onCaptureFailed(message) { errorText.visible = true }
  }

  onOpenedChanged: {
    if (opened) {
      service.refresh()
      if (!service.camerasLoaded) service.refreshCameras()
    } else {
      cursorActive = false
    }
  }

  IpcHandler {
    target: "sphiment.omavcam"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(): void { service.start() }
    function stop(): void { service.stop() }
    function toggleCapture(): void { service.toggle() }
    function togglePreview(): void { service.togglePreview() }
    function togglePreviewSnap(): void { root.togglePreviewSnap() }
    function cameraState(): string {
      return JSON.stringify({ loaded: service.camerasLoaded,
                              deferred: service.camerasDeferred,
                              count: service.cameras.length,
                              hasDevice: service.hasDevice,
                              running: service.running,
                              streaming: service.streaming })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.concealed ? "" : root.icon
    foreground: root.barIconColor
    onPressed: function (b) {
      if (b === Qt.RightButton) service.toggle()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // 380 is the shared width for bar popups — audio, bluetooth, network,
    // monitor, power, tailscale and agents all use it. This panel was 20 units
    // narrower for no reason, which is visible the moment it opens next to one
    // of them.
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // PanelKeyCatcher owns Keys.onPressed itself, so the dialog is driven
      // through its signals rather than by intercepting raw key events — an
      // instance-level Keys.onPressed here simply never fires.
      onMoveRequested: function (dx, dy) {
        if (root.originalWarningOpen && dx !== 0)
          originalWarning.selectedIndex = originalWarning.selectedIndex === 0 ? 1 : 0
      }
      onActivateRequested: {
        if (!root.originalWarningOpen) return
        if (originalWarning.selectedIndex === 0) originalWarning.canceled()
        else originalWarning.confirmed()
      }
      onCloseRequested: {
        if (root.originalWarningOpen) root.originalWarningOpen = false
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        // The dialog is modal: nothing behind it should act on a keystroke.
        if (root.originalWarningOpen) return
        var key = String(t).toLowerCase()
        if (key === "s") service.toggle()
        else if (key === "r") { service.refresh(); service.refreshCameras() }
        else if (key === "f") root.chooseFacing("front")
        else if (key === "b") root.chooseFacing("back")
        else if (key === "p") service.togglePreview()
        else if (key === "e") root.togglePreviewSnap()
        else if (key === "+" || key === "=") root.choosePreviewSize(nextPreviewSize(1))
        else if (key === "-" || key === "_") root.choosePreviewSize(nextPreviewSize(-1))
      }

      ConfirmDialog {
        id: originalWarning
        anchors.fill: parent
        z: 10
        opened: root.originalWarningOpen
        message: root.originalWarningText
        confirmText: "Show anyway"
        cancelText: "Cancel"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.originalWarningOpen = false
        onConfirmed: {
          root.originalWarningOpen = false
          service.setPreviewSize("original")
        }
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Hero: state, and the switch that changes it ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, captureSwitch.implicitHeight)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: service.active ? 1.0 : 0.5
          }

          ToggleSwitch {
            id: captureSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: service.active
            busy: service.busy
            interactive: service.hasDevice && !service.needsInstall
            foreground: root.foreground
            onToggled: service.toggle()

            PanelToolTip {
              visible: captureSwitch.containsMouse
              text: service.active ? "Stop the virtual camera" : "Start the virtual camera"
              fontFamily: root.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: captureSwitch.width + Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "omavcam"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: service.statusText().toUpperCase()
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Dependencies missing ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: service.needsInstall

          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            text: "omavcam needs " + Model.missingPackagesText(service.missingPackages) + "."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Button {
            text: "Install dependencies"
            fontFamily: root.fontFamily
            onClicked: service.runSetup()
          }
        }

        // ---------- Something else is blocking ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !service.needsInstall && !!service.blockingIssue

          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            text: service.blockingIssue ? service.blockingIssue.message : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Phone ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !service.needsInstall

          PanelSeparator { width: parent.width }
          PanelSectionHeader { text: "PHONE"; foreground: root.foreground; fontFamily: root.fontFamily }

          Text {
            width: parent.width
            visible: service.devices.length === 0
            text: "Plug a phone in and enable USB debugging."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: service.devices

            Item {
              required property var modelData
              width: column.width
              implicitHeight: Style.space(22)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Model.deviceLabel(modelData)
                color: modelData.ready ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width - stateLabel.width - Style.space(10)
              }

              Text {
                id: stateLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: Model.deviceStateText(modelData.state)
                color: modelData.ready ? root.dim : root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---------- Camera ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !service.needsInstall && service.hasDevice

          PanelSeparator { width: parent.width }
          PanelSectionHeader { text: "CAMERA"; foreground: root.foreground; fontFamily: root.fontFamily }

          ButtonGroup {
            width: parent.width
            options: [
              {value: "front", label: "Front"},
              {value: "back", label: "Back"}
            ]
            value: String(service.setting("facing", "front"))
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function (value) { root.chooseFacing(value) }
          }

          Dropdown {
            width: parent.width
            label: "Resolution"
            visible: service.sizeOptions.length > 0
            fontFamily: root.fontFamily
            options: {
              var out = [{value: "", label: "Camera default"}]
              var sizes = Model.shortlistSizes(service.sizeOptions, 6)
              for (var i = 0; i < sizes.length; i++) out.push({value: sizes[i], label: sizes[i]})
              return out
            }
            value: String(service.setting("size", ""))
            onChanged: function (value) {
              root.persist({size: value})
              service.applyLive({size: value})
            }
          }

          Text {
            width: parent.width
            visible: !service.camerasLoaded
            text: "Reading the phone's cameras…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: service.camerasDeferred
            text: "Camera details will refresh after the stream stops."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Preview ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !service.needsInstall && service.streaming

          PanelSeparator { width: parent.width }

          Item {
            width: parent.width
            implicitHeight: Math.max(previewHeader.implicitHeight, previewSwitch.implicitHeight)

            PanelSectionHeader {
              id: previewHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "PREVIEW"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ToggleSwitch {
              id: previewSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: service.previewOpen
              busy: service.busy
              foreground: root.foreground
              onToggled: service.togglePreview()

              PanelToolTip {
                visible: previewSwitch.containsMouse
                text: service.previewOpen ? "Close the preview" : "Show what the other side sees"
                fontFamily: root.fontFamily
              }
            }
          }

          ButtonGroup {
            width: parent.width
            visible: service.previewOpen
            options: [
              {value: "small", label: "Small"},
              {value: "medium", label: "Medium"},
              {value: "large", label: "Large"},
              {value: "original", label: "Original"}
            ]
            value: service.previewSize
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function (value) { root.choosePreviewSize(value) }
          }

          Column {
            width: parent.width
            spacing: Style.space(7)

            PanelSectionHeader {
              text: "SNAP TARGETS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              width: parent.width
              label: "All"
              description: "Every magnetic point"
              checked: service.previewSnapEdges
                       && service.previewSnapCorners
                       && service.previewSnapCenter
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.togglePreviewSnap()
            }

            Toggle {
              width: parent.width
              label: "Edges"
              description: "Top, right, bottom, and left middles"
              checked: service.previewSnapEdges
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleSnapTarget("edges")
            }

            Toggle {
              width: parent.width
              label: "Corners"
              description: "All four screen corners"
              checked: service.previewSnapCorners
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleSnapTarget("corners")
            }

            Toggle {
              width: parent.width
              label: "Center"
              description: "The middle of the screen"
              checked: service.previewSnapCenter
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleSnapTarget("center")
            }
          }

          ButtonGroup {
            width: parent.width
            options: [
              {value: "loopback", label: "Virtual cam"},
              {value: "scrcpy", label: "scrcpy window"}
            ]
            value: service.previewSource
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function (value) {
              service.changePreviewMode(value, service.previewSurface)
            }
          }

          ButtonGroup {
            width: parent.width
            visible: service.previewSource === "loopback"
            options: [
              {value: "overlay", label: "Overlay"},
              {value: "window", label: "Window"}
            ]
            value: service.previewSurface
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function (value) {
              service.changePreviewMode(service.previewSource, value)
            }
          }

          Text {
            width: parent.width
            text: {
              if (service.previewSize === "original")
                return "Original is the stream's real pixel size, so it can be larger than the screen."
              return service.previewSource === "loopback"
                     ? (service.previewSurface === "overlay"
                        ? "Drawn by omavcam itself, with smooth dragging between screens."
                        : "An mpv window showing exactly what the other side sees.")
                     : "Shows scrcpy's window, which can also control the phone. Switching it restarts the stream."
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Last failure ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: errorText.visible && service.lastError !== ""

          PanelSeparator { width: parent.width }

          Text {
            id: errorText
            visible: false
            width: parent.width
            text: service.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
