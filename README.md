# omavcam

The Omarchy wrapper for the omavcam daemon. It adds a bar widget for starting
and stopping capture, choosing a phone, toggling the preview, and seeing
connection problems before a call.

This repository contains no capture engine and runs no system commands. The
widget is a thin client: it connects to the daemon's Unix socket, renders the
whole state pushed by the daemon, and sends requests back over that socket.

## Install

Install the engine first. Until the daemon repository is renamed, its releases
are published from `Sphiment/omavcam2`:

```sh
# Use the headers package matching your kernel: linux-headers,
# linux-lts-headers, linux-zen-headers, or linux-hardened-headers.
sudo pacman -Syu linux-headers

sudo pacman -U https://github.com/Sphiment/omavcam2/releases/latest/download/omavcam-git-x86_64.pkg.tar.zst
```

Reboot after installing the engine. To use it immediately without rebooting:

```sh
sudo modprobe v4l2loopback
systemctl --user daemon-reload
systemctl --user start omavcam.socket
```

Then install this wrapper:

```sh
omarchy plugin add https://github.com/Sphiment/omavcam.git --enable
```

`--enable` interactively asks where to place the widget in the bar. On the
phone, enable Developer options and USB debugging, connect it, and accept the
debugging prompt. The panel can then start the camera; the same operation is
available from a terminal with `omavcam start`.

If the engine is absent or cannot start, the panel shows the engine install
command and the systemd status command to use. It deliberately does not install
anything itself.

## Remove

Remove the wrapper without touching the engine:

```sh
omarchy plugin remove sphiment.omavcam
```

To remove both halves:

```sh
systemctl --user stop omavcam.socket omavcam.service
sudo pacman -Rns omavcam-git
omarchy plugin remove sphiment.omavcam
```

## Architecture

The widget expects protocol version 4. It keeps one connection to
`$OMAVCAM_SOCKET`, or `$XDG_RUNTIME_DIR/omavcam.sock` by default. Connecting
socket-activates the daemon. State changes made by the CLI, a phone, or the
capture process are pushed to the widget; the wrapper does not poll or retain a
second copy of daemon state.

The wrapper also forwards Omarchy's live corner-radius and border-width tokens
when it asks the daemon to show the preview. All `adb`, `scrcpy`, `hyprctl`,
module, capture, and persistence work belongs to the daemon.

## Development

The wrapper has no build step. Run its structural tests with:

```sh
python -m unittest discover -s tests -v
```

The tests validate the manifest and enforce the client boundary: QML may use
the socket API, but it may not spawn processes or invoke capture tools.

## License

MIT — see [LICENSE](LICENSE).
