# omavcam roadmap

Built in phases, one pull request each. Every phase leaves the plugin in a
working state.

## Design decisions

| Question | Decision |
|---|---|
| Capture source | Phone **camera** and phone **screen**, switchable in the UI |
| Transport | **USB** and **wireless** (`adb tcpip`) |
| UI surface | **Bar widget + panel**, modelled on `omarchy.tailscale` |
| Dependency install | Detect, then offer an install through Omarchy's floating terminal |
| v4l2 device | One fixed labelled node, `/dev/video42`, `card_label="omavcam"` |
| Preview | Headless by default; floating movable window, toggleable |
| Preview source | Loopback (`mpv`) or scrcpy's own window, user's choice |
| Preview placement | Nine named anchors, remembered; plain drag snaps, `Super`+drag is free |
| Hyprland rules | Applied at runtime with `hyprctl keyword` — never writes to your config |
| Phone microphone | Deferred; `v4l2loopback` is video-only and audio needs a PipeWire path |

`exclusive_caps=1` on the loopback node is load-bearing: the node only
advertises capture capability while something is writing to it, so "omavcam"
appears in app camera pickers exactly when you are streaming, and is absent
otherwise. No phantom camera in every dropdown.

## Architecture

Every system interaction lives in `bin/omavcam`, a plain bash CLI. The QML only
reads its JSON output and calls its subcommands. The whole feature is therefore
testable from a terminal, and a broken shell plugin can never strand a `scrcpy`
process.

| File | Role |
|---|---|
| `manifest.json` | Plugin id, kinds, and the bar widget's settings schema |
| `Panel.qml` | Bar button and popup panel |
| `Service.qml` | State machine: dependencies, devices, capture and preview lifecycle |
| `Model.js` | Pure parsers and formatters — no QML |
| `bin/omavcam` | The entire system surface |

## Phases

- [x] **0 — Scaffold.** Repo, license, CI, a manifest that validates, and a bar
      widget stub that loads.
- [x] **1 — `doctor` + `setup`.** Dependency detection, package install, module
      configuration, and a JSON health report.
- [x] **2 — Camera capture over USB.** `devices`, `cameras`, `start`, `stop`,
      `status`. A working webcam, from the terminal.
- [x] **3 — Bar widget and panel.** The UI over the CLI: device list, camera
      controls, start/stop, and the missing-dependency install prompt.
- [x] **4 — Floating preview.** Movable, pinned preview window, from either the
      loopback node or scrcpy's own window.
- [x] **4.1 — Snapping.** Nine anchors that clear the bar, a drag-release
      magnet with a threshold, the position remembered across reboots, and a
      setting to turn the whole thing off. Dragging the window by its picture
      snaps; holding `Super` places it freely.
- [ ] **5 — Screen mirror mode.** Mirror the phone's display into the webcam.
- [ ] **6 — Wireless transport.** `adb tcpip`, remembered devices, connection
      states.
- [ ] **7 — Publish.** Screenshots, complete settings schema, error copy, and
      submission to the Omarchy plugin catalog.

### Deferred

**Phone microphone.** `scrcpy --audio-source=mic` into a PipeWire null-sink via
`pw-loopback`, so the phone's mic appears as an input device. The service is
structured to accept it; it is not built yet.
