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

You do not have to install these by hand — omavcam detects what is missing and
offers to install it from the panel, using Omarchy's own package installer.
`v4l2loopback-dkms` is built by DKMS, so the headers for your running kernel
(`linux-headers`, or the matching package for `linux-lts`, `linux-zen`, and so
on) are installed alongside it.

`mpv` and `jq` are also used, and ship with Omarchy.

All of these are ordinary Arch packages installed from the official
repositories, and each carries its own license: scrcpy and `android-tools` are
Apache-2.0, `v4l2loopback-dkms` is GPL-2.0-or-later, `mpv` is GPL-2.0-or-later,
and `jq` is MIT. omavcam bundles none of them — it calls them.

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
| `p` | Show or hide the preview window |
| `+` / `-` | Step the preview through small, medium, large, original |
| `e` | Snap the preview to edges, or let it float free |
| `r` | Re-read the phone, its cameras, and the system state |
| `esc` | Close |

### The preview window

The preview is an ordinary floating window: pinned above everything, movable
and resizable like any other, and it takes no focus when it appears. Three size
presets scale from your monitor's height, so the same preset looks the same on
a 1080p screen and a 4K one, and the window always keeps the stream's aspect
ratio.

Sizes are `small`, `medium`, `large`, and `original`. The first three scale from
your monitor's height. **`original` is the stream's real pixel size, and is not
scaled down** — a phone that out-resolves your monitor gives a window larger
than the screen, on purpose. It is placed at the top-left corner so you can drag
it from there.

Because that is easy to ask for by accident, choosing `original` asks first when
the stream really is bigger than the screen it would open on:

> The preview would be 3264×2448, larger than this screen (2048×1152). It will
> extend past the edges — drag it by its top-left corner.

The check is made against the monitor the preview would land on, not a fixed
threshold, so it is right on a laptop panel and on a 4K display, and it changes
when you move the window to another monitor. A stream that fits is applied
without asking.

There are two things it can show:

| Source | Shows | Trade-off |
|---|---|---|
| **Virtual cam** (default) | The `/dev/video42` node itself | Exactly the frames the other side receives — same crop, same orientation, same lag. Independent of the capture, so it opens and closes freely. |
| **scrcpy window** | scrcpy's own window | No second process, and you can tap the phone from your desktop. It is part of the capture, so turning it on or off restarts the stream. |

omavcam applies its Hyprland rules at runtime with `hyprctl`, so installing it
never writes into your Hyprland config.

### Snapping

Drag the preview by its picture — plain left button, no modifier — and let go
near a corner, an edge, or the middle of the screen, and it parks itself there:
clear of the bar, with the same margin everywhere. Let go anywhere else and it
stays exactly where you dropped it. The snap is a magnet with a range, not a
grid you are stuck to.

**Hold `Super` while you drag and nothing snaps at all.** That is the way to put
the preview somewhere the magnet would otherwise pull it off: same drag you use
on any other window, and it lands exactly where you let go.

Wherever it ends up is remembered, so resizing it or closing and reopening it
puts it back in the same place rather than returning it to the corner. Drag it
onto a second monitor and it snaps to that monitor's edges.

Snapping happens in two halves, because the compositor owns a window's position
for as long as a drag lasts and overwrites anything moved underneath it. So the
magnet you feel *while* dragging is Hyprland's own — omavcam switches
`general:snap` on while the preview is open and puts your previous setting back
when it closes. Note that this is compositor-wide: every floating window snaps
while the preview is up.

Hyprland's magnet parks a window flush against the edge, which is not where a
preview wants to sit, and its `monitor_gap` is the distance at which the magnet
grabs rather than the distance it leaves. So the gap is omavcam's half: when you
let go, the preview settles into place a fraction of a second later, carried
there by the compositor's own move animation.

That gap scales with the screen rather than being a fixed number of pixels —
4.5% of the monitor's logical height, between 24 and 96 pixels, which is 40 on a
1600x900 desktop and 48 on a 4K one at 200% scale. Logical pixels already carry
the display's scale, so a HiDPI panel gets the same apparent gap instead of a
hairline.

The two drags are told apart by mpv rather than guessed at: a plain click lands
on the preview's own window, so mpv marks it and starts the move itself, while a
`Super` drag is taken by the compositor before mpv hears anything at all. Which
also means the preview's mouse bindings are omavcam's own while it is open — a
double click will not put it fullscreen.

The scrcpy preview is the exception: clicks on it go to the phone, so `Super`
is the only way to move that window and snapping stays on for it.

Turn it off with `e` in the panel, from the plugin's settings, or from a
terminal:

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
