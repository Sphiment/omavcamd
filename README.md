# omavcam

<img width="990" height="595" alt="image" src="https://github.com/user-attachments/assets/839df77f-d195-4551-b7e2-ce4f100c3a46" />

Use an Android phone as a virtual webcam on Linux — as a first-class
[Omarchy](https://omarchy.org) shell plugin.

`scrcpy` can already pipe a phone's camera or screen into a `v4l2loopback`
node, which Meet, Zoom, OBS, and Discord then see as an ordinary webcam.
omavcam wraps that in a bar widget: one click to start, a keyboard-driven panel
to pick the device, camera, and resolution, and a movable floating preview of
exactly what the other side sees.

> **Status: in development.** See [ROADMAP.md](ROADMAP.md) for what is built and
> what is coming.

## Install

```bash
omarchy plugin add https://github.com/Sphiment/omavcam.git --enable
```

Then place it on the bar:

```bash
omarchy bar move sphiment.omavcam
```

## Removing it

```bash
omavcam uninstall                          # undo the system configuration
omarchy plugin remove sphiment.omavcam     # remove the plugin
```

`uninstall` deletes the two files `setup` wrote, unloads the `v4l2loopback`
module if nothing else is using it, stops any capture, and clears omavcam's
state — both the runtime kind and the preferences it saved, such as where you
last parked the preview. It asks first, and leaves the packages alone unless you pass
`--packages`.

Removing the plugin without running `uninstall` leaves the module config behind;
it is harmless, but it is yours to delete:

```bash
sudo rm -f /etc/modprobe.d/omavcam.conf /etc/modules-load.d/omavcam.conf
```

omavcam never writes to your Hyprland config, so there is nothing to undo there.

## Requirements

| Package | Why |
|---|---|
| `scrcpy` | Captures the phone's camera or screen |
| `android-tools` | `adb`, for talking to the phone |
| `v4l2loopback-dkms` | The kernel module backing the virtual camera node |
| `qt6-multimedia` | Draws the in-shell preview overlay |

You do not have to install these by hand — omavcam detects what is missing and
offers to install it from the panel, using Omarchy's own package installer.
`v4l2loopback-dkms` is built by DKMS, so the headers for your running kernel
(`linux-headers`, or the matching package for `linux-lts`, `linux-zen`, and so
on) are installed alongside it.

`qt6-multimedia` is required by the shell overlay, but not by the standalone
CLI: capture and the mpv preview continue to work without it.

`mpv` and `jq` are also used. `mpv` remains the preview used by the CLI and by
the panel's optional window mode.

All of these are ordinary Arch packages installed from the official
repositories, and each carries its own license: scrcpy and `android-tools` are
Apache-2.0, `v4l2loopback-dkms` is GPL-2.0-or-later, Qt Multimedia is
LGPL-3.0/GPL-2.0+/GPL-3.0, `mpv` is GPL-2.0-or-later, and `jq` is MIT. omavcam
bundles none of them — it calls them.

To do it from a terminal instead:

```bash
bin/omavcam doctor    # what is missing, and whether it blocks capture
bin/omavcam setup     # install dependencies and configure the virtual camera
```

`setup` writes two files, both marked as managed by omavcam:

| File | Contents |
|---|---|
| `/etc/modprobe.d/omavcam.conf` | `video_nr=42 card_label="omavcam" exclusive_caps=1 max_openers=10` |
| `/etc/modules-load.d/omavcam.conf` | `v4l2loopback`, so the node returns after a reboot |

`exclusive_caps=1` means the node only advertises capture capability while
something is writing to it, so "omavcam" appears in camera pickers exactly when
you are streaming rather than sitting in every dropdown. Set `OMAVCAM_VIDEO_NR`
if `/dev/video42` is already taken on your machine — any whole number from 0 to
255, the range of video device minors. It is refused rather than written if it
is anything else, since that value lands in a root-owned file that `modprobe`
later reads with privileges.

## License

MIT — see [LICENSE](LICENSE).

## Using it

Click the bar icon to open the panel; right-click the icon to start or stop
capture without opening anything. Inside the panel:

| Key | Does |
|---|---|
| `s` | Start or stop the virtual camera |
| `f` / `b` | Switch to the front or back camera |
| `p` | Show or hide the preview |
| `+` / `-` | Step the preview through small, medium, large, original |
| `e` | Toggle all preview snap targets on or off |
| `r` | Re-read the phone, its cameras, and the system state |
| `esc` | Close |

### The preview

The virtual-camera preview is drawn by omavcam in a transparent layer-shell
overlay by default. The full-screen compositor surface never moves; only the
video tile inside it does. That makes dragging, magnetic anchors, easing, and
multi-monitor handoff smooth even on Wayland, while every pixel outside the
tile remains click-through.

The overlay is part of the plugin, not a general camera viewer. It is created
only while omavcam's own scrcpy process is alive and its verified `omavcam`
loopback node is streaming. Stopping or losing the capture destroys the camera
reader and closes the preview. Device selection requires both the exact node
path and the exact `omavcam` label; it never falls back to a laptop webcam or
another camera.

Sizes are `small`, `medium`, `large`, and `original`. The first three scale from
the current monitor's logical height. **`original` is the stream's real pixel
size, and is not scaled down** — a phone that out-resolves a monitor is clipped
at that monitor's boundary rather than being split between two screens.

Because that is easy to ask for by accident, choosing `original` asks first when
the stream really is bigger than the screen it would open on:

> The preview would be 3264×2448, larger than this screen (2048×1152). It will
> extend past the edges.

The check is made against the monitor the preview would land on, not a fixed
threshold, so it is right on a laptop panel and on a 4K display, and it changes
when you move the window to another monitor. A stream that fits is applied
without asking.

There are two sources and two surfaces:

| Choice | Shows | Trade-off |
|---|---|---|
| **Virtual cam · Overlay** (default) | The verified omavcam loopback node inside the shell | Exactly what the other side receives, with smooth plugin-owned dragging and live Omarchy theme colors, borders, and corners. |
| **Virtual cam · Window** | The same node in mpv | Retains an ordinary compositor-managed window; this is also what `omavcam preview on` uses from a terminal. |
| **scrcpy window** | scrcpy's own window | Lets you control the phone, but showing or hiding it restarts the capture. It cannot be embedded in the overlay. |

Only the two window modes need runtime Hyprland rules. Installing omavcam never
writes to your Hyprland configuration.

### Snapping

Drag the overlay preview by its picture and let go near an enabled magnetic
point to park it there. Let go outside the magnet's reach and it stays where it
was dropped. The panel exposes an independent checklist:

| Choice | Magnetic points |
|---|---|
| **Edges** | Top, right, bottom, and left edge centres |
| **Corners** | All four screen corners |
| **Center** | The middle of the screen |
| **All** | Checks or clears every choice above |

Any combination works. Checking all three groups is exactly the same as
checking **All**, while clearing all three makes placement completely free.

Each target is a complete point rather than an independent horizontal or
vertical line, so moving near one axis no longer makes most of the screen feel
sticky.

Its last named anchor and monitor are remembered, so resizing or reopening puts
it back in the same place. The cursor decides when a drag crosses monitors; the
whole tile eases onto the new screen and is never divided across them.

The gap scales with the screen rather than being a fixed number of pixels —
4.5% of the monitor's logical height, between 24 and 96 pixels, which is 40 on a
1600x900 desktop and 48 on a 4K one at 200% scale. Logical pixels already carry
the display's scale, so a HiDPI panel gets the same apparent gap instead of a
hairline.

The optional mpv and scrcpy windows retain their previous compositor-managed
dragging behavior. Use `Super` to drag scrcpy, because plain clicks belong to
the phone.

All targets can also be disabled from a terminal; `on` retains the window
preview's existing all-points behavior:

```bash
omavcam preview snap off
```

The same nine positions are available by name, which is handy for a keybinding:

```bash
omavcam preview move top-right
```

Changes apply to a running stream. scrcpy fixes the camera, resolution and
frame rate when it launches, so none of them can be altered on a live stream —
omavcam re-establishes the capture with the new setting instead of making you
stop and start by hand. Expect a couple of seconds during which the virtual
camera goes away and comes back; a meeting app will usually pick it straight
back up, but it is a visible blip, not a seamless switch.

Resolutions belong to a camera, not to the phone, so switching cameras drops a
resolution the new one does not offer and falls back to its default.

Your camera and resolution choices are saved on the widget's entry in
`~/.config/omarchy/shell.json`, so they survive a restart. Everything the panel
exposes is also available from `omavcam` on the command line.

## Development

```bash
git clone https://github.com/Sphiment/omavcam.git
cd omavcam
omarchy plugin validate .          # same checks the shell enforces at load

# The shell refuses symlinks inside a plugin folder, so sync rather than link:
rsync -a --delete --exclude '.git' --exclude '.github' ./ \
  ~/.config/omarchy/plugins/sphiment.omavcam/
```

Saving a file under `~/.config/omarchy/plugins/` hot-reloads the plugin's code.
**Adding a bar widget for the first time needs a full `omarchy-restart-shell`** —
hot reload picks up code changes to plugins the bar already knows about, not a
newly registered widget.

QML errors and plugin reloads show up in `journalctl --user -f`.
