import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar widget and the panel behind it.
//
// This file holds no state and makes no system calls. It opens the daemon's
// socket, renders what it is pushed, and sends requests; every `scrcpy`,
// `adb` and `hyprctl` invocation lives in the separate daemon
// (ADR-0001). Connecting is also what makes the daemon exist: the listening
// socket is systemd's, and something connecting to it is the only thing that
// starts the service behind it.
//
// The panel is deliberately thin — a light, a switch, and the phones whenever
// there is more than one to point at (ADR-0007). Settings live in Studio,
// never here: the frequent action has to be instant.
Panel {
  id: root
  moduleName: "omavcam"
  ipcTarget: "omavcam"

  // The protocol the daemon speaks, from src/protocol.rs. A mismatch is
  // reported rather than misparsed.
  readonly property int protocol: 4

  // The whole state, exactly as pushed, or null while we have not been told.
  // Not `state`: every QML Item already has one of those.
  property var daemonState: null

  // Whether the socket has actually failed, as opposed to not having answered
  // yet. Without it the widget would show trouble for the frame between
  // connecting and the first push, which is trouble that is not happening.
  property bool unreachable: false

  // The id of the request we are waiting on, or "". A switch and a picker
  // cannot generate more than one at a time.
  property string pending: ""
  property int nextId: 1

  // What the daemon last refused, in its own words. The panel shows it; the
  // bar does not, because a refused request is not a broken setup.
  property string refusal: ""
  readonly property int previewRounding: Style.cornerRadius
  readonly property int previewBorderSize: Style.normalBorderWidth

  // The socket is rebuilt to reconnect, so it is null for a moment each time.
  readonly property bool socketUp: link.item !== null && link.item.connected
  readonly property bool linked: socketUp && daemonState !== null
  readonly property bool capturing: !!(daemonState && daemonState.capture)
  readonly property bool previewing: !!(capturing && daemonState.capture.preview)
  readonly property string connectionState: daemonState ? daemonState.connection.state : ""
  readonly property bool reconnecting: connectionState === "reconnecting"
  readonly property int reconnectPreviewHeight: {
    var size = capturing ? String(daemonState.capture.size).split("x") : []
    var width = size.length === 2 ? Number(size[0]) : 0
    var height = size.length === 2 ? Number(size[1]) : 0
    return width > 0 && height > 0 ? Math.max(1, Math.round(640 * height / width)) : 360
  }

  // What omavcam needs and has not got, in the daemon's own words: each entry
  // is a `what` and the `package` that supplies it. The daemon re-checks on
  // every pass, so this empties itself once the install happens.
  readonly property var missing: daemonState ? (daemonState.missing || []) : []

  // What the bar has to warn about: something is wrong and only the person at
  // the desk can fix it. No phone attached is not trouble, it is Tuesday.
  readonly property bool troubled: daemonState
    ? (missing.length > 0
      || !daemonState.adb_ok
      || connectionState === "unauthorised"
      || connectionState === "pairing_failed"
      || connectionState === "unreachable"
      || reconnecting)
    : unreachable

  // The phone the connection names, in whatever phase it is in.
  readonly property string selectedSerial: {
    var connection = daemonState ? daemonState.connection : null
    return connection && connection.phone ? connection.phone.serial : ""
  }

  // The phones worth offering. One phone that is already the one in use is no
  // choice at all; anything else is — two on the desk, or one that has never
  // been picked because a different phone is the remembered one.
  //
  // Read from the state's own list rather than from `Unselected.available`,
  // which is the same phones and goes away when the protocol version next
  // moves.
  readonly property var choices: {
    if (!daemonState) return []
    var choices = (daemonState.attached || []).slice()
    var knownPhones = daemonState.known || []
    knownPhones.forEach(function (known) {
      if (known.transport === "wireless"
          && !choices.some(function (item) {
            return item.phone.serial === known.phone.serial
              || item.phone.serial === known.hardware_id
          })) {
        choices.push({"phone": known.phone, "authorised": true})
      }
    })
    if (choices.length === 1 && choices[0].phone.serial === selectedSerial) return []
    return choices
  }

  // What the picker has to say before someone clicks it, not after.
  function pickerNote() {
    var notes = []
    if (capturing) notes.push("Switching stops the capture")
    if (choices.some(function (phone) { return phone.authorised === false }))
      notes.push("A dimmed phone has not accepted the debugging prompt")
    return notes.join(" · ")
  }

  // Where the daemon's socket is, by the same rule the daemon uses. Named once
  // because the Socket below and the install offer must not disagree about
  // which path went unanswered.
  readonly property string socketPath: Quickshell.env("OMAVCAM_SOCKET")
    || (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omavcam.sock"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- the daemon --------------------------------------------------------

  function send(kind, args) {
    if (!root.socketUp || pending !== "") return
    refusal = ""
    var request = {"v": protocol, "id": String(nextId++), "kind": kind}
    if (args) Object.keys(args).forEach(function(key) { request[key] = args[key] })
    pending = request.id
    link.item.write(JSON.stringify(request) + "\n")
    link.item.flush()
  }

  // Phone names, serials and the tool errors quoted back in refusals are all
  // written by the device, and every Text in the shell's shared components is
  // Text.AutoText — Qt decides on its own whether a string is markup. A model
  // name of "<img src=…>" would then be a phone deciding what the bar renders
  // and what it fetches. Stripping the angle brackets is what makes that
  // decision impossible; nothing Qt calls rich text survives without them.
  //
  // Done here, where the daemon's words enter, because it is the only door:
  // the Texts below can be told to stay plain, but PanelHero, Toggle and
  // Button belong to the shell and cannot.
  function plain(value) {
    if (typeof value === "string") return value.replace(/[<>]/g, "")
    if (Array.isArray(value)) return value.map(root.plain)
    if (value && typeof value === "object") {
      var copy = {}
      Object.keys(value).forEach(function(key) { copy[key] = root.plain(value[key]) })
      return copy
    }
    return value
  }

  function receive(line) {
    var message
    // The socket is the daemon's and mode 0600, but a line we cannot parse
    // must not take the widget down with it.
    try {
      // Sanitised after parsing, not before: what reaches a Text is the decoded
      // string, and an encoder that escaped the brackets would slip a raw line
      // past a check made on the raw line.
      message = plain(JSON.parse(line))
    } catch (e) {
      return
    }
    if (message.v !== protocol) {
      refusal = "the daemon speaks protocol " + message.v + ", this widget speaks " + protocol
      return
    }
    if (message.type === "state") {
      daemonState = message.state
      syncPreviewStyle()
    } else if (message.type === "response" && message.id === pending) {
      pending = ""
      refusal = message.ok ? "" : message.error.message
      if (message.ok) syncPreviewStyle()
    }
  }

  function toggleCapture() {
    send(capturing ? "stop" : "start", capturing ? null : previewArgs(true))
  }

  function previewArgs(visible) {
    return {
      "visible": visible,
      "rounding": Style.cornerRadius,
      "border_size": Style.normalBorderWidth
    }
  }

  function togglePreview() {
    send("preview", previewArgs(!previewing))
  }

  // A shell restart reconnects to the same daemon and the same scrcpy window.
  // Reapply the live tokens without owning any geometry or capture state here.
  function syncPreviewStyle() {
    if (!capturing || reconnecting || pending !== "") return
    var applied = daemonState.preview_style || {"rounding": 0, "border_size": 1}
    if (applied.rounding === previewRounding && applied.border_size === previewBorderSize) return
    send("preview", previewArgs(previewing))
  }

  onPreviewRoundingChanged: syncPreviewStyle()
  onPreviewBorderSizeChanged: syncPreviewStyle()

  // ---- what all that says ------------------------------------------------

  function connectionWords() {
    if (!root.socketUp) return "Daemon unreachable"
    if (!daemonState) return "Waiting for the daemon"
    if (!daemonState.adb_ok) return "adb unavailable"
    var connection = daemonState.connection
    if (connection.state === "no_phone") return "No phone"
    if (connection.state === "unselected") return daemonState.attached.length + " phones attached, none chosen"
    if (connection.state === "unauthorised") return connection.phone.name + " has not accepted the debugging prompt"
    if (connection.state === "connecting") return "Connecting to " + connection.phone.name
    if (connection.state === "connected") return connection.phone.name + " connected"
    if (connection.state === "reconnecting") return "Reconnecting to " + connection.phone.name + " — last frame held"
    if (connection.state === "needs_pairing") return "Wireless pairing needed — run omavcam pair"
    if (connection.state === "pairing_failed") {
      if (connection.reason === "wrong_code") return "Wireless pairing failed — wrong code"
      if (connection.reason === "wrong_address") return "Wireless pairing failed — wrong pairing address"
      return "Wireless pairing failed — phone may be on a different network"
    }
    if (connection.state === "unreachable")
      return connection.phone.name + " unreachable — check the network or connect port"
    return connection.state
  }

  // A missing engine is the one thing the panel cannot ask the daemon about,
  // because the daemon is the engine. An unanswered socket that has stayed
  // unanswered across retries is either not installed or not starting, and
  // both are installs — never a stack trace. A daemon being restarted is not:
  // it comes back inside the first wait, so the offer waits for the interval
  // to have stretched rather than telling someone to install what they have.
  //
  // The offer is the command, not a button: this file runs nothing (ADR-0001),
  // and every command below the first line is the daemon's own words.
  function installWords() {
    if (!root.socketUp) {
      if (retry.interval === retry.firstInterval) return ""
      return "No engine answered " + root.socketPath + ".\n"
        + "Install the engine:\n"
        + "sudo pacman -U https://github.com/Sphiment/omavcam2/releases/latest/download/omavcam-git-x86_64.pkg.tar.zst\n"
        + "Already installed? systemctl --user status omavcam.socket omavcam.service"
    }
    return root.missing.map(function (item) {
      return "Missing " + item.what + "\n  " + item.install
    }).join("\n")
  }

  function captureWords() {
    if (reconnecting && capturing) return "Reconnecting to " + daemonState.capture.phone.name + " — last frame held"
    if (capturing) return daemonState.capture.size + " from " + daemonState.capture.phone.name
    return "Off — omavcam is in no camera list"
  }

  function tooltipWords() {
    if (reconnecting && capturing) return "omavcam — reconnecting to " + daemonState.capture.phone.name
    if (capturing) return "omavcam — capturing from " + daemonState.capture.phone.name
    return "omavcam — " + connectionWords()
  }

  // nf-md-video (U+F03D), nf-fa-warning (U+F071), nf-md-video_off (U+F0568):
  // a running capture, something only the person at the desk can fix, and off.
  readonly property string icon: reconnecting ? "" : (capturing ? "" : (troubled ? "" : "󰕨"))
  readonly property color light: reconnecting ? urgent : (capturing ? Color.accent : (troubled ? urgent : Qt.darker(foreground, 1.8)))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A Socket that has failed to dial is spent: `connected` reads false but
  // writing it true again does nothing and never reaches the listener. So
  // reconnecting means building a new one, which is why the socket lives in a
  // Loader instead of standing on its own.
  Loader {
    id: link
    active: true
    sourceComponent: Socket {
      // Connecting is what socket-activates the daemon, so the widget holds
      // the link open whether the panel is showing or not — the bar has to
      // know about a capture nobody started from here.
      connected: true
      path: root.socketPath

      parser: SplitParser {
        splitMarker: "\n"
        onRead: function(line) { root.receive(line) }
      }

      onError: root.unreachable = true

      // A daemon that goes away leaves nothing to render and no answer coming.
      // Forgetting both is what keeps the widget from wedging.
      onConnectionStateChanged: {
        if (connected) {
          root.unreachable = false
          retry.interval = retry.firstInterval
        } else {
          root.daemonState = null
          root.pending = ""
        }
      }
    }
  }

  // Reconnecting is the whole recovery: the daemon pushes its state on
  // connect, so there is nothing to resync. The wait doubles because a daemon
  // that cannot start at all must not be asked to twice a second forever —
  // socket activation would answer every attempt with another failed start.
  Timer {
    id: retry
    readonly property int firstInterval: 2000
    interval: firstInterval
    repeat: true
    running: !root.socketUp
    onTriggered: {
      link.active = false
      link.active = true
      interval = Math.min(interval * 2, 30000)
    }
  }

  // The daemon answers every request, so silence this long means it will not.
  // Matches the CLI's own patience.
  Timer {
    interval: 20000
    running: root.pending !== ""
    onTriggered: {
      root.pending = ""
      root.refusal = "the daemon did not answer"
    }
  }

  // scrcpy owns the video window and necessarily exits with the phone. Keep
  // that same preview place honest while its requested visibility is on: this
  // status-only window decodes nothing and never reads the virtual camera.
  FloatingWindow {
    id: reconnectPreview
    visible: root.reconnecting && root.previewing
    title: "omavcam reconnecting"
    implicitWidth: 640
    implicitHeight: root.reconnectPreviewHeight
    color: Color.background

    Rectangle {
      anchors.fill: parent
      color: Color.background
      radius: root.previewRounding
      border.width: Math.max(1, root.previewBorderSize)
      border.color: root.urgent

      Column {
        anchors.centerIn: parent
        width: Math.max(1, parent.width - Style.space(48))
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Reconnecting…"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.capturing ? root.daemonState.capture.phone.name + " · camera stays selected" : ""
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.capturing || root.troubled
    activeColor: root.reconnecting ? root.urgent : (root.capturing ? Color.accent : root.urgent)
    tooltipText: root.tooltipWords()
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.toggleCapture()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- the light, and what it is saying ----------
        PanelHero {
          title: "omavcam"
          meta: root.connectionWords()
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Rectangle {
            width: Style.space(12)
            height: width
            radius: width / 2
            color: root.light

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- the switch ----------
        Toggle {
          width: parent.width
          label: "Capture"
          description: root.captureWords()
          checked: root.capturing
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: root.linked
          opacity: enabled ? 1 : 0.5
          onClicked: root.toggleCapture()
        }

        Toggle {
          width: parent.width
          label: "Preview"
          description: root.reconnecting ? "Unavailable while reconnecting" : (root.capturing ? (root.previewing ? "Visible" : "Hidden") : "Start a capture first")
          checked: root.previewing
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: root.linked && root.capturing && !root.reconnecting
          opacity: enabled ? 1 : 0.5
          onClicked: root.togglePreview()
        }

        // ---------- the picker, only while there is a choice ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.choices.length > 0

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "PHONES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // One line explains every dimmed row, and warns about the one
          // click in this panel that takes something away.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.pickerNote()
            visible: text !== ""
            color: root.capturing ? root.urgent : Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.choices

            Button {
              required property var modelData
              width: parent.width
              text: modelData.phone.name
              iconText: "" // nf-fa-mobile
              leftAlign: true
              // The one in use, so a picker offered in every state still says
              // which phone the webcam is pointed at.
              selected: modelData.phone.serial === root.selectedSerial
              // Dimmed, not disabled: selecting it is how the panel comes to
              // say which phone needs the prompt accepted, and a row that
              // cannot be clicked is a dead end instead of an instruction.
              opacity: modelData.authorised === false ? 0.55 : 1
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: modelData.phone.serial
              onClicked: root.send("select", {"serial": modelData.phone.serial})
            }
          }
        }

        // ---------- what is not installed ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.installWords() !== ""

          PanelSeparator { foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.installWords()
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- what the daemon refused ----------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.refusal !== ""
          text: root.refusal
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
