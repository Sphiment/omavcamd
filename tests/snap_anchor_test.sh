#!/usr/bin/env bash

# The preview's snap geometry: which of the nine anchors a dropped window is
# pulled onto, and where it lands. All of it is arithmetic over numbers the
# compositor would have reported, so the hidden __snap-origin and __snap-nearest
# subcommands take those numbers as arguments and the whole feature can be
# exercised with no Hyprland, no phone and no monitors — which is exactly what
# CI has.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
readonly OMAVCAM=bin/omavcam

# A 2560x1440 desktop with a 40px bar reserved at the top, and a 640x360
# preview on it. The margin is proportional to the monitor's height, so it is
# asked for rather than written down — the point of these checks is the rule,
# not its arithmetic.
readonly SCREEN=(0 0 2560 1440 0 40 0 0)
readonly WINDOW=(640 360)
readonly BAR=40
MARGIN=$("$OMAVCAM" __snap-margin 1440)
readonly MARGIN

readonly ANCHORS=(
  top-left top top-right
  left center right
  bottom-left bottom bottom-right
)

fails=0

check() {
  local label="$1" want="$2" got="$3"

  if [[ $got == "$want" ]]; then
    printf '  pass  %s\n' "$label"
  else
    fails=$((fails + 1))
    printf '  FAIL  %s\n        got  %s\n        want %s\n' "$label" "$got" "$want"
  fi
}

origin() {
  "$OMAVCAM" __snap-origin "$1" "${SCREEN[@]}" "${WINDOW[@]}"
}

nearest() {
  "$OMAVCAM" __snap-nearest "${SCREEN[@]}" "${WINDOW[@]}" "$1" "$2"
}

printf 'Each anchor is inside the bar and the margin\n'

# The usable box is the screen less the bar and the margin on every side.
# Nothing may be placed outside it.
readonly LEFT=$MARGIN
readonly RIGHT=$((2560 - MARGIN))
readonly TOP=$((BAR + MARGIN))
readonly BOTTOM=$((1440 - MARGIN))

for anchor in "${ANCHORS[@]}"; do
  read -r x y < <(origin "$anchor")
  inside=yes
  ((x >= LEFT && x + WINDOW[0] <= RIGHT)) || inside=no
  ((y >= TOP && y + WINDOW[1] <= BOTTOM)) || inside=no
  check "$anchor is within the usable box" yes "$inside"
done

# The top row must clear the bar, which is the whole point of reading the
# reserved area rather than the raw monitor rectangle.
read -r _ y < <(origin top)
check "top clears the reserved bar" "$TOP" "$y"

read -r x _ < <(origin center)
check "center is centred horizontally" 960 "$x"

printf '\nA drop near an anchor snaps to it\n'

# 30px right and 20px up from each anchor: well inside the threshold, which is
# 12%% of the screen height (172px here), and not so symmetric that a wrong
# anchor would coincidentally match.
for anchor in "${ANCHORS[@]}"; do
  read -r x y < <(origin "$anchor")
  check "a drop 30,-20 from $anchor snaps back to it" \
    "$anchor $x $y" "$(nearest "$((x + 30))" "$((y - 20))")"
done

printf '\nA drop in open space is left alone\n'

check "the middle of nowhere snaps to nothing" none "$(nearest 500 400)"

# 173px away on one axis is just past the threshold; 171px is just inside it.
read -r x y < <(origin center)
check "one pixel past the threshold does not snap" none "$(nearest "$((x + 173))" "$y")"
check "one pixel inside the threshold snaps" \
  "center $x $y" "$(nearest "$((x + 171))" "$y")"

printf '\nThe gap grows with the screen, and never runs away with it\n'

check "a laptop panel gets a modest gap" 30 "$("$OMAVCAM" __snap-margin 675)"
check "a 1440p screen gets a bigger one" 64 "$("$OMAVCAM" __snap-margin 1440)"
check "an enormous screen is capped" 96 "$("$OMAVCAM" __snap-margin 4000)"
check "a tiny screen still gets a usable gap" 24 "$("$OMAVCAM" __snap-margin 100)"

printf '\nAn oversized preview keeps the axis it overflows\n'

# `original` on a phone that out-resolves the monitor: 4080x3060 on 2048x1152.
# Both axes overflow, so there is no anchor to be at and no snap to make.
check "a window larger than the screen never snaps" none \
  "$("$OMAVCAM" __snap-nearest 0 0 2048 1152 0 40 0 0 4080 3060 -500 600)"

# Only the width overflows: the vertical edges still snap, and the horizontal
# position the user dragged to is preserved rather than pulled to a corner.
small_margin=$("$OMAVCAM" __snap-margin 1152)
bottom_edge=$((40 + small_margin + (1152 - 40 - 2 * small_margin) - 400))
read -r anchor x y < <("$OMAVCAM" __snap-nearest 0 0 2048 1152 0 40 0 0 4080 400 -300 700)
check "a too-wide window keeps its x" "-300" "$x"
check "a too-wide window still snaps to the bottom edge" "$bottom_edge" "$y"
check "a too-wide window reports the bottom edge, not a corner" bottom "$anchor"

printf '\nBad input is refused\n'

"$OMAVCAM" __snap-origin nowhere "${SCREEN[@]}" "${WINDOW[@]}" >/dev/null 2>&1
check "an unknown anchor is rejected" 1 "$?"

"$OMAVCAM" __snap-nearest 1 2 3 >/dev/null 2>&1
check "too few numbers are rejected" 1 "$?"

"$OMAVCAM" __snap-nearest 0 0 2560 1440 0 40 0 0 640 360 12 'x; rm -rf /' >/dev/null 2>&1
check "a non-numeric coordinate is rejected" 1 "$?"

printf '\n'
if ((fails == 0)); then
  printf 'All snap geometry checks passed.\n'
else
  printf '%s check(s) failed.\n' "$fails"
fi
exit $((fails > 0))
