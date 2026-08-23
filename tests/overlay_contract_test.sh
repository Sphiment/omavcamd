#!/usr/bin/env bash

# The overlay must never turn into a general-purpose camera preview. These are
# source-level contract checks because CI has neither QtMultimedia nor a Wayland
# compositor; the live QML harness is run during development on Omarchy.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0

check() {
  local label="$1" result="$2"
  if [[ $result == yes ]]; then
    printf '  pass  %s\n' "$label"
  else
    fails=$((fails + 1))
    printf '  FAIL  %s\n' "$label"
  fi
}

service=$(tr '\n' ' ' <Service.qml)
overlay=$(tr '\n' ' ' <Overlay.qml)
cli=$(tr '\n' ' ' <bin/omavcam)

singleton=no
jq -e '.kinds | index("service")' manifest.json >/dev/null &&
  [[ $(jq -r '.entryPoints.service' manifest.json) == Service.qml ]] && singleton=yes
check "the overlay owner is a singleton plugin service" "$singleton"

default_surface=no
[[ $(jq -r '.barWidget.defaults.previewSurface' manifest.json) == overlay ]] &&
  [[ $(jq -r '.barWidget.defaults.previewSource' manifest.json) == loopback ]] &&
  default_surface=yes
check "the panel defaults to the loopback overlay" "$default_surface"

dependency_safe=no
[[ $service == *'id: overlayLoader'*'active: root.multimediaAvailable'* ]] &&
  [[ $service == *'source: active ? Qt.resolvedUrl("Overlay.qml") : ""'* ]] &&
  [[ $service == *'String(packages[i].name || "") === "qt6-multimedia"'* ]] &&
  dependency_safe=yes
check "missing Qt Multimedia does not prevent doctor or setup from loading" "$dependency_safe"

stable_media=no
[[ $service == *'var mediaInstalled = false'* ]] &&
  [[ $service == *'root.multimediaAvailable = mediaInstalled'* ]] &&
  [[ $service != *'root.multimediaAvailable = false'* ]] && stable_media=yes
check "doctor polling does not recreate the overlay loader" "$stable_media"

stable_capture_identity=no
# These are deliberately literal source fragments, not expressions for this
# test shell to expand.
# shellcheck disable=SC2016
[[ $cli == *'cmdline=$(tr'*'grep -q -- "--v4l2-sink=$DEVICE" <<<"$cmdline"'* ]] &&
  [[ $cli != *'tr '\''\\0'\'' '\'' '\'' </proc/"$pid"/cmdline | grep -q'* ]] &&
  stable_capture_identity=yes
check "capture PID validation cannot fail from grep SIGPIPE" "$stable_capture_identity"

readonly_status=no
status_body=${cli#*cmd_status()}
status_body=${status_body%%cmd_preview()*}
[[ $status_body != *'clear_state'* ]] && readonly_status=yes
check "status never erases capture ownership state" "$readonly_status"

serialized_capture=no
[[ $cli == *'capture_lock()'*'flock -x 9'* ]] &&
  [[ $cli == *'cmd_start() {   capture_lock'* ]] &&
  [[ $cli == *'cmd_stop() {   capture_lock'* ]] &&
  [[ $cli == *'cmd_status()'*'capture_lock'* ]] &&
  [[ $cli == *'cmd_restart() {   capture_lock'* ]] &&
  [[ $cli == *'setsid --fork sh -c'* ]] && serialized_capture=yes
check "capture actions serialize and record the real scrcpy child" "$serialized_capture"

lifecycle=no
[[ $service == *'readonly property bool overlayCaptureReady: overlayPreviewOpen'* ]] &&
  [[ $service == *'&& overlayMode'*'&& running'*'&& streaming'*'&& !reapplying'* ]] &&
  [[ $service == *'&& loopbackDeviceOwned'*'String(capture.device || "") === loopbackDevicePath'* ]] &&
  [[ $service == *'onRunningChanged:'*'overlayPreviewOpen = false'* ]] &&
  [[ $service == *'onStreamingChanged:'*'overlayPreviewOpen = false'* ]] &&
  lifecycle=yes
check "display requires omavcam's live capture and closes with it" "$lifecycle"

lazy_media=no
[[ $overlay == *'Loader {'*'id: mediaLoader'*'active: root.previewActive'* ]] &&
  [[ $overlay == *'MediaDevices { id: devices }'* ]] && lazy_media=yes
check "camera discovery is lazy and follows overlay activity" "$lazy_media"

exact_camera=no
[[ $overlay == *'String(candidate.id) === root.devicePath'* ]] &&
  [[ $overlay == *'String(candidate.description).trim().toLowerCase()'* ]] &&
  [[ $overlay == *'=== root.deviceLabel.trim().toLowerCase()'* ]] &&
  [[ $overlay == *'active: media.cameraReady && root.previewActive'* ]] &&
  [[ $overlay != *'defaultVideoInput'* ]] && exact_camera=yes
check "camera selection requires the exact path and omavcam label" "$exact_camera"

themed_surface=no
[[ $overlay == *'import qs.Commons'* ]] &&
  [[ $overlay == *'import qs.Ui'* ]] &&
  [[ $overlay == *'BorderSurface {'* ]] &&
  [[ $overlay == *'color: Color.background'* ]] &&
  [[ $overlay == *'radius: Style.cornerRadius'* ]] &&
  [[ $overlay == *'themeBorderSpec: Border.hyprlandActiveSpec('*'Color.accent'* ]] &&
  [[ $overlay != *'border.color: "#40ffffff"'* ]] &&
  [[ $overlay != *'color: "#000000"'* ]] && themed_surface=yes
check "overlay chrome follows Omarchy and Hyprland theme tokens" "$themed_surface"

seamless_border=no
[[ $overlay == *'id: videoFrame'*'anchors.fill: parent'* ]] &&
  [[ $overlay == *'id: borderChrome'*'z: 1'*'borderSpec: tile.themeBorderSpec'* ]] &&
  [[ $overlay == *'id: pointer'*'z: 2'* ]] &&
  [[ $overlay != *'anchors.topMargin: tile.borderTop'* ]] && seamless_border=yes
check "video extends beneath the top-painted border without an inner seam" "$seamless_border"

active_workarea=no
[[ $overlay == *'property var reservedByScreen: ({})'* ]] &&
  [[ $overlay == *'command: ["hyprctl", "-j", "monitors"]'* ]] &&
  [[ $overlay == *'function activeBox(s)'* ]] &&
  [[ $overlay == *'s.width - r.left - r.right'* ]] &&
  [[ $overlay == *'s.height - r.top - r.bottom'* ]] &&
  [[ $overlay == *'box.x + Math.round((box.width - w) / 2)'* ]] &&
  [[ $overlay == *'box.y + Math.round((box.height - h) / 2)'* ]] && active_workarea=yes
check "edges, corners, and center use each monitor's active work area" "$active_workarea"

snap_checklist=no
[[ $overlay == *'property bool snapEdges: true'* ]] &&
  [[ $overlay == *'property bool snapCorners: true'* ]] &&
  [[ $overlay == *'property bool snapCenter: true'* ]] &&
  [[ $overlay == *'var edges = ["top", "right", "bottom", "left"]'* ]] &&
  [[ $overlay == *'if (edgesEnabled) result = result.concat(edges)'* ]] &&
  [[ $overlay == *'if (cornersEnabled) result = result.concat(corners)'* ]] &&
  [[ $overlay == *'if (centerEnabled) result.push("center")'* ]] &&
  [[ $overlay == *'function magnetPoint('* ]] &&
  [[ $service == *'readonly property bool previewSnapEdges:'* ]] &&
  [[ $service == *'function setPreviewSnapTargets(edges, corners, center)'* ]] && snap_checklist=yes
check "snap target groups can be checked independently or all together" "$snap_checklist"

camera_loading=no
[[ $service == *'property bool cameraRefreshRequested: false'* ]] &&
  [[ $service == *'function maybeRefreshCameras()'* ]] &&
  [[ $service == *'actionProcess.running || reapplying || running || streaming'* ]] &&
  [[ $service == *'camerasDeferred = true'*'camerasLoaded = true'* ]] &&
  [[ $service == *'cameraRefreshRequested = current !== ""'* ]] && camera_loading=yes
check "camera loading queues early requests and never spins behind a live capture" "$camera_loading"

printf '\n'
if ((fails == 0)); then
  printf 'All overlay ownership checks passed.\n'
else
  printf '%s check(s) failed.\n' "$fails"
fi
exit $((fails > 0))
