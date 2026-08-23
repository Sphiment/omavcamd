pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// One plugin-owned preview, drawn into a layer-shell surface on each screen.
// The service creates this component once. There is deliberately only one
// Camera and it is re-pointed at the VideoOutput belonging to the current
// screen: Qt refuses multiple readers for the same device in one process.
Item {
  id: root

  property bool previewActive: false
  property bool snapEdges: true
  property bool snapCorners: true
  property bool snapCenter: true
  property string sizeName: "small"
  property string savedAnchor: "bottom-right"
  property string savedScreen: ""
  property string devicePath: ""
  property string deviceLabel: "omavcam"
  property int nativeWidth: 0
  property int nativeHeight: 0
  property var reservedByScreen: ({})

  readonly property var originalInfo: {
    var s = layout.byName(preview.screenName)
    if (!s || nativeWidth <= 0 || nativeHeight <= 0) return null
    var box = layout.activeBox(s)
    return {
      width: nativeWidth,
      height: nativeHeight,
      screenWidth: box.width,
      screenHeight: box.height,
      fitsScreen: nativeWidth <= box.width && nativeHeight <= box.height
    }
  }

  signal placementCommitted(string screenName, string anchor)
  signal cameraError(string message)

  QtObject {
    id: preview

    property real gx: 0
    property real gy: 0
    property int w: 320
    property int h: 240
    property string screenName: ""
    property bool eased: false
    property bool dragging: false
    property string draggerName: ""
    property int magnetX: -1
    property int magnetY: -1
    property bool initialized: false

    Behavior on gx {
      NumberAnimation { duration: preview.eased ? 170 : 0; easing.type: Easing.OutCubic }
    }
    Behavior on gy {
      NumberAnimation { duration: preview.eased ? 170 : 0; easing.type: Easing.OutCubic }
    }
  }

  QtObject {
    id: layout

    function gapFor(s) {
      return Math.max(24, Math.min(96, Math.round(s.height * 0.045)))
    }

    function reservedFor(s) {
      var value = root.reservedByScreen[String(s.name)]
      return value || { left: 0, top: 0, right: 0, bottom: 0 }
    }

    // The monitor's usable workspace after every exclusive layer surface is
    // removed. Hyprland supplies these four margins independently per screen.
    function activeBox(s) {
      var r = reservedFor(s)
      return {
        x: s.x + r.left,
        y: s.y + r.top,
        width: Math.max(1, s.width - r.left - r.right),
        height: Math.max(1, s.height - r.top - r.bottom)
      }
    }

    function reachFor(s, w, h) {
      var base = Math.max(80, Math.min(200, Math.round(s.height * 0.12)))
      var spanX = Math.abs(anchorsX(s, w)[1] - anchorsX(s, w)[0])
      var spanY = Math.abs(anchorsY(s, h)[1] - anchorsY(s, h)[0])
      var room = Math.floor(Math.min(spanX, spanY) / 3)
      return Math.max(24, Math.min(base, room))
    }

    function contains(s, x, y) {
      return x >= s.x && x < s.x + s.width && y >= s.y && y < s.y + s.height
    }

    function screenAt(x, y) {
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) {
        if (contains(screens[i], x, y)) return screens[i]
      }
      return null
    }

    function byName(name) {
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) {
        if (screens[i].name === name) return screens[i]
      }
      return null
    }

    // Layouts with differently sized screens have holes. When the pointer is
    // in one, use the screen with the nearest edge rather than losing the drag.
    function nearest(x, y) {
      var screens = Quickshell.screens
      if (screens.length === 0) return null
      var best = screens[0]
      var closest = Infinity
      for (var i = 0; i < screens.length; i++) {
        var s = screens[i]
        var dx = Math.max(s.x - x, 0, x - (s.x + s.width))
        var dy = Math.max(s.y - y, 0, y - (s.y + s.height))
        var distance = dx * dx + dy * dy
        if (distance < closest) {
          closest = distance
          best = s
        }
      }
      return best
    }

    function clamp(value, low, high) {
      // An original-size preview may be larger than the screen. Keep its
      // top-left reachable instead of manufacturing an inverted clamp range.
      return Math.max(low, Math.min(Math.max(low, high), value))
    }

    function anchorsX(s, w) {
      var box = activeBox(s)
      var gap = gapFor(s)
      return [box.x + gap,
              box.x + Math.round((box.width - w) / 2),
              box.x + box.width - w - gap]
    }

    function anchorsY(s, h) {
      var box = activeBox(s)
      var gap = gapFor(s)
      return [box.y + gap,
              box.y + Math.round((box.height - h) / 2),
              box.y + box.height - h - gap]
    }

    function snapAnchors(edgesEnabled, cornersEnabled, centerEnabled) {
      var edges = ["top", "right", "bottom", "left"]
      var corners = ["top-left", "top-right", "bottom-right", "bottom-left"]
      var result = []
      if (edgesEnabled) result = result.concat(edges)
      if (cornersEnabled) result = result.concat(corners)
      if (centerEnabled) result.push("center")
      return result
    }

    // Snap to named points, not independent horizontal and vertical lines.
    // The previous line magnets combined into many accidental targets, which
    // made most of the screen feel sticky even though there are only 9 anchors.
    function magnetPoint(x, y, s, w, h, reach,
                         edgesEnabled, cornersEnabled, centerEnabled) {
      var names = snapAnchors(edgesEnabled, cornersEnabled, centerEnabled)
      var xs = anchorsX(s, w)
      var ys = anchorsY(s, h)
      var box = activeBox(s)
      var best = null
      var bestDistance = reach * reach + 1

      for (var i = 0; i < names.length; i++) {
        var indexes = anchorIndexes(names[i])
        var ax = clamp(xs[indexes.x], box.x, box.x + box.width - w)
        var ay = clamp(ys[indexes.y], box.y, box.y + box.height - h)
        var dx = x - ax
        var dy = y - ay
        var distance = dx * dx + dy * dy
        if (distance < bestDistance) {
          bestDistance = distance
          best = { x: ax, y: ay, xIndex: indexes.x, yIndex: indexes.y }
        }
      }

      return best && bestDistance <= reach * reach
        ? { x: best.x, y: best.y, snapped: true,
            xIndex: best.xIndex, yIndex: best.yIndex }
        : { x: x, y: y, snapped: false, xIndex: -1, yIndex: -1 }
    }

    function anchorName(xIndex, yIndex) {
      var rows = [
        ["top-left", "top", "top-right"],
        ["left", "center", "right"],
        ["bottom-left", "bottom", "bottom-right"]
      ]
      if (xIndex < 0 || xIndex > 2 || yIndex < 0 || yIndex > 2) return ""
      return rows[yIndex][xIndex]
    }

    function anchorIndexes(name) {
      var names = [
        "top-left", "top", "top-right",
        "left", "center", "right",
        "bottom-left", "bottom", "bottom-right"
      ]
      var index = names.indexOf(name)
      if (index < 0) index = 8
      return { x: index % 3, y: Math.floor(index / 3) }
    }
  }

  function sizeFor(s) {
    var width = nativeWidth > 0 ? nativeWidth : 16
    var height = nativeHeight > 0 ? nativeHeight : 9

    if (sizeName === "original" && nativeWidth > 0 && nativeHeight > 0) {
      return { width: nativeWidth, height: nativeHeight }
    }

    var fraction = sizeName === "small" ? 0.18 : (sizeName === "large" ? 0.34 : 0.25)
    var wantedHeight = Math.max(1, Math.round(s.height * fraction))
    var wantedWidth = Math.max(1, Math.round(wantedHeight * width / height))
    var box = layout.activeBox(s)
    var availableWidth = Math.max(1, box.width - 2 * layout.gapFor(s))
    if (wantedWidth > availableWidth) {
      wantedWidth = availableWidth
      wantedHeight = Math.max(1, Math.round(wantedWidth * height / width))
    }
    return { width: wantedWidth, height: wantedHeight }
  }

  function placeAtSavedAnchor(animate) {
    var s = layout.byName(preview.screenName)
    if (!s) return
    var size = sizeFor(s)
    var indexes = layout.anchorIndexes(savedAnchor)
    var box = layout.activeBox(s)
    preview.eased = animate === true
    preview.w = size.width
    preview.h = size.height
    preview.gx = layout.clamp(layout.anchorsX(s, preview.w)[indexes.x],
                              box.x, box.x + box.width - preview.w)
    preview.gy = layout.clamp(layout.anchorsY(s, preview.h)[indexes.y],
                              box.y, box.y + box.height - preview.h)
    preview.magnetX = indexes.x
    preview.magnetY = indexes.y
  }

  function ensureOwner() {
    var screens = Quickshell.screens
    if (screens.length === 0) {
      preview.screenName = ""
      preview.initialized = false
      return
    }

    var owner = layout.byName(preview.screenName)
    if (!owner) owner = layout.byName(savedScreen)
    if (!owner) owner = screens[0]
    var changed = preview.screenName !== owner.name
    preview.screenName = owner.name
    if (!preview.initialized || changed) {
      preview.initialized = true
      placeAtSavedAnchor(false)
    }
    attachOwnerOutput()
  }

  function attachOwnerOutput() {
    if (!mediaLoader.item) return
    var windows = overlayVariants.instances || []
    for (var i = 0; i < windows.length; i++) {
      var window = windows[i]
      if (window && window.modelData && window.modelData.name === preview.screenName) {
        mediaLoader.item.videoOutput = window.previewOutput
        return
      }
    }
  }

  function adjustToActiveArea(animate) {
    var s = layout.byName(preview.screenName)
    if (!s || !preview.initialized || preview.dragging) return
    var box = layout.activeBox(s)
    preview.eased = animate === true
    if (preview.magnetX >= 0 && preview.magnetY >= 0) {
      preview.gx = layout.clamp(layout.anchorsX(s, preview.w)[preview.magnetX],
                                box.x, box.x + box.width - preview.w)
      preview.gy = layout.clamp(layout.anchorsY(s, preview.h)[preview.magnetY],
                                box.y, box.y + box.height - preview.h)
    } else {
      preview.gx = layout.clamp(preview.gx, box.x, box.x + box.width - preview.w)
      preview.gy = layout.clamp(preview.gy, box.y, box.y + box.height - preview.h)
    }
  }

  function normalizedReserved(value) {
    var number = Number(value)
    return isFinite(number) ? Math.max(0, Math.round(number)) : 0
  }

  function applyReservedAreas(raw) {
    var monitors
    try { monitors = JSON.parse(String(raw || "")) } catch (error) { return }
    if (!Array.isArray(monitors)) return

    var next = {}
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i] || {}
      var reserved = Array.isArray(monitor.reserved) ? monitor.reserved : []
      next[String(monitor.name || "")] = {
        left: normalizedReserved(reserved[0]),
        top: normalizedReserved(reserved[1]),
        right: normalizedReserved(reserved[2]),
        bottom: normalizedReserved(reserved[3])
      }
    }

    if (JSON.stringify(next) === JSON.stringify(reservedByScreen)) return
    reservedByScreen = next
    adjustToActiveArea(true)
  }

  function refreshReservedAreas() {
    if (!reservedProcess.running) reservedProcess.running = true
  }

  onSavedAnchorChanged: if (preview.initialized && !preview.dragging) placeAtSavedAnchor(true)
  onSavedScreenChanged: if (preview.initialized && !preview.dragging) {
    var s = layout.byName(savedScreen)
    if (s && preview.screenName !== s.name) {
      preview.screenName = s.name
      placeAtSavedAnchor(true)
      attachOwnerOutput()
    }
  }
  onSizeNameChanged: if (preview.initialized && !preview.dragging) placeAtSavedAnchor(true)
  onNativeWidthChanged: if (preview.initialized && !preview.dragging) placeAtSavedAnchor(false)
  onNativeHeightChanged: if (preview.initialized && !preview.dragging) placeAtSavedAnchor(false)
  onPreviewActiveChanged: if (previewActive) refreshReservedAreas()
  Component.onCompleted: {
    Qt.callLater(ensureOwner)
    Qt.callLater(refreshReservedAreas)
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      Qt.callLater(root.ensureOwner)
      Qt.callLater(root.refreshReservedAreas)
    }
  }

  Process {
    id: reservedProcess
    command: ["hyprctl", "-j", "monitors"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyReservedAreas(text)
    }
  }

  // Bars and docks can change their exclusive zone without monitor geometry
  // changing. Refresh only while visible; hyprctl is not polled when idle.
  Timer {
    interval: 3000
    running: root.previewActive
    repeat: true
    onTriggered: root.refreshReservedAreas()
  }

  // MediaDevices is intentionally born only after omavcam is known to be
  // streaming. QtMultimedia caches its first device enumeration forever; if it
  // is constructed at login, exclusive_caps means the omavcam node is absent
  // and it can never appear in this process. Destroying this loader on every
  // stop/restart also discards a stale QCameraDevice.
  Loader {
    id: mediaLoader
    active: root.previewActive
    sourceComponent: mediaComponent
    onItemChanged: Qt.callLater(root.attachOwnerOutput)
  }

  Component {
    id: mediaComponent

    Item {
      id: media

      property alias videoOutput: session.videoOutput
      readonly property var exactDevice: {
        var inputs = devices.videoInputs
        for (var i = 0; i < inputs.length; i++) {
          var candidate = inputs[i]
          var idMatches = String(candidate.id) === root.devicePath
          var labelMatches = String(candidate.description).trim().toLowerCase()
                           === root.deviceLabel.trim().toLowerCase()
          // Both checks are load-bearing. Matching only the path can show a
          // physical webcam that later claimed the same node; matching only the
          // label can attach to an unrelated, similarly named loopback device.
          if (idMatches && labelMatches) return candidate
        }
        return null
      }
      readonly property bool cameraReady: exactDevice !== null && exactDevice !== undefined

      MediaDevices { id: devices }

      CaptureSession {
        id: session
        camera: Camera {
          id: camera
          active: media.cameraReady && root.previewActive
          onErrorOccurred: function(error, message) {
            if (message) root.cameraError(String(message))
          }
        }
      }

      // Avoid assigning null to QCameraDevice while still refusing Qt's
      // default camera: the Camera remains inactive until this exact-device
      // binding has a value.
      Binding {
        target: camera
        property: "cameraDevice"
        value: media.exactDevice
        when: media.cameraReady
      }
    }
  }

  Variants {
    id: overlayVariants
    model: Quickshell.screens

    PanelWindow {
      id: overlay
      required property var modelData
      readonly property bool ownsPreview: preview.screenName === modelData.name
      readonly property bool holdsDrag: preview.dragging && preview.draggerName === modelData.name
      property alias previewOutput: output

      screen: modelData
      visible: root.previewActive
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "omavcam-preview"

      // Never collapse the region under an active pointer grab. Away from a
      // drag, only the visible tile receives input; every other pixel passes
      // straight through to the desktop below.
      mask: Region {
        x: overlay.holdsDrag ? 0 : tile.x
        y: overlay.holdsDrag ? 0 : tile.y
        width: overlay.holdsDrag ? overlay.width
                                 : (root.previewActive && overlay.ownsPreview ? tile.width : 0)
        height: overlay.holdsDrag ? overlay.height
                                  : (root.previewActive && overlay.ownsPreview ? tile.height : 0)
      }

      onOwnsPreviewChanged: if (ownsPreview) root.attachOwnerOutput()
      Component.onCompleted: Qt.callLater(root.ensureOwner)

      Rectangle {
        id: tile
        x: preview.gx - overlay.modelData.x
        y: preview.gy - overlay.modelData.y
        width: preview.w
        height: preview.h
        // The old surface keeps the pointer grab while a drag crosses screens.
        // visible:false would cancel it; opacity preserves input and the grab.
        opacity: overlay.ownsPreview ? 1 : 0
        color: Color.background
        radius: Style.cornerRadius
        antialiasing: true
        clip: true
        readonly property var themeBorderSpec: Border.hyprlandActiveSpec(
                                                  Color.accent,
                                                  Math.max(1, Style.space(2)))

        // The video fills the tile and the border is painted over it below.
        // Insetting video to the border's nominal inner edge exposes a moving
        // one-pixel seam when Qt antialiases that edge at fractional positions.
        Rectangle {
          id: videoMask
          anchors.fill: videoFrame
          radius: videoFrame.radius
          color: "white"
          visible: false
          layer.enabled: tile.radius > 0 && root.previewActive && overlay.ownsPreview
        }

        Item {
          id: videoFrame
          anchors.fill: parent
          readonly property real radius: tile.radius
          layer.enabled: tile.radius > 0 && root.previewActive && overlay.ownsPreview
          layer.smooth: true
          layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: videoMask
            maskThresholdMin: 0.3
            maskSpreadAtMin: 0.15
          }

          VideoOutput {
            id: output
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectFit
          }
        }

        // Keep every border pixel above the video. This handles flat,
        // gradient, and per-side Omarchy borders without allowing the camera
        // texture to cover their antialiased inner edge.
        BorderSurface {
          id: borderChrome
          anchors.fill: parent
          z: 1
          color: "transparent"
          radius: tile.radius
          antialiasing: true
          borderSpec: tile.themeBorderSpec
        }

        MouseArea {
          id: pointer
          anchors.fill: parent
          z: 2
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          property real grabX: 0
          property real grabY: 0

          onPressed: function(mouse) {
            grabX = mouse.x
            grabY = mouse.y
            preview.eased = false
            preview.dragging = true
            preview.draggerName = overlay.modelData.name
          }

          onCanceled: preview.dragging = false

          onReleased: {
            preview.dragging = false
            root.adjustToActiveArea(false)
            var anchor = layout.anchorName(preview.magnetX, preview.magnetY)
            root.placementCommitted(preview.screenName, anchor)
          }

          onPositionChanged: function(mouse) {
            if (!pressed) return

            // The pointer chooses the owner screen. It crosses a seam before
            // the tile does, letting the whole preview hop without ever showing
            // half a video and half a black rectangle.
            var cursorX = preview.gx + mouse.x
            var cursorY = preview.gy + mouse.y
            var s = layout.screenAt(cursorX, cursorY) || layout.nearest(cursorX, cursorY)
            if (!s) return

            var crossed = s.name !== preview.screenName
            if (crossed) {
              var oldWidth = preview.w
              var oldHeight = preview.h
              var newSize = root.sizeFor(s)
              preview.w = newSize.width
              preview.h = newSize.height
              grabX = oldWidth > 0 ? grabX * preview.w / oldWidth : grabX
              grabY = oldHeight > 0 ? grabY * preview.h / oldHeight : grabY
              preview.screenName = s.name
              root.attachOwnerOutput()
            }

            var wantedX = preview.gx + mouse.x - grabX
            var wantedY = preview.gy + mouse.y - grabY
            var activeBox = layout.activeBox(s)
            wantedX = layout.clamp(wantedX, activeBox.x,
                                   activeBox.x + activeBox.width - preview.w)
            wantedY = layout.clamp(wantedY, activeBox.y,
                                   activeBox.y + activeBox.height - preview.h)

            var magnet = { x: wantedX, y: wantedY, snapped: false,
                           xIndex: -1, yIndex: -1 }
            if (root.snapEdges || root.snapCorners || root.snapCenter) {
              var reach = layout.reachFor(s, preview.w, preview.h)
              magnet = layout.magnetPoint(wantedX, wantedY, s,
                                           preview.w, preview.h, reach,
                                           root.snapEdges, root.snapCorners,
                                           root.snapCenter)
            }

            preview.magnetX = magnet.xIndex
            preview.magnetY = magnet.yIndex
            preview.eased = crossed || magnet.snapped
            preview.gx = magnet.x
            preview.gy = magnet.y
          }
        }
      }
    }
  }

  // Kept as a diagnostic seam for geometry testing without synthesising a
  // Wayland pointer drag.
  IpcHandler {
    target: "sphiment.omavcam.overlay"
    function owner(): string {
      return preview.screenName + " @ " + Math.round(preview.gx) + "," + Math.round(preview.gy)
    }
    function targets(mask: int): string {
      return layout.snapAnchors((mask & 1) !== 0,
                                (mask & 2) !== 0,
                                (mask & 4) !== 0).join(",")
    }
    function workarea(screenName: string): string {
      var screen = layout.byName(screenName)
      return screen ? JSON.stringify(layout.activeBox(screen)) : "{}"
    }
    function anchor(screenName: string, name: string): string {
      var screen = layout.byName(screenName)
      if (!screen) return ""
      var indexes = layout.anchorIndexes(name)
      var box = layout.activeBox(screen)
      var x = layout.clamp(layout.anchorsX(screen, preview.w)[indexes.x],
                           box.x, box.x + box.width - preview.w)
      var y = layout.clamp(layout.anchorsY(screen, preview.h)[indexes.y],
                           box.y, box.y + box.height - preview.h)
      return Math.round(x) + "," + Math.round(y)
    }
    function place(x: int, y: int): void {
      preview.eased = false
      preview.gx = x
      preview.gy = y
    }
  }
}
