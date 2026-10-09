#!/usr/bin/env bash
# Render a stand-in for the band intro film so the intro screen can be previewed
# and screenshotted before the real render lands in Loopr/Loopr/Resources/Onboarding.
#
# Writes band-intro.mp4, band-intro-poster.png and band-intro.timings.json to
# $1 (default /tmp/loopr-band-intro-placeholder). Never point it at the app's
# Resources folder: that folder only holds the real film.
#
# Beats follow design/onboarding-band/CONTRACT.md: a grey block (the hand) rises
# until 1.4 s, a bar (the band) appears at 1.4 s, grows through the wrap from
# 1.9 s, flashes at the click at 3.0 s, and the frame holds from 4.6 s. The top
# 36 % of the frame stays empty for the text.

set -euo pipefail

OUT="${1:-/tmp/loopr-band-intro-placeholder}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
BG="0x0A0D11"

case "$OUT" in
  *Resources/Onboarding*) echo "refusing to write the placeholder into the app's Resources/Onboarding" >&2; exit 1 ;;
esac
mkdir -p "$OUT"

FILTER="\
drawbox=x=560:y='2340-min(t/1.4\,1)*1250':w=380:h=1400:color=0x3A4250:t=fill,\
drawbox=x=520:y=1330:w='if(lt(t\,1.9)\,40\,40+min((t-1.9)/1.1\,1)*420)':h=90:color=0x2AD4E6:t=fill:enable='gte(t\,1.4)',\
drawbox=x=0:y=0:w=iw:h=ih:color=white@0.35:t=fill:enable='between(t\,3.0\,3.06)'"

"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=$BG:s=1080x2340:r=60:d=4.6" \
  -vf "$FILTER" \
  -an -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -x265-params log-level=error \
  "$OUT/band-intro.mp4"

"$FFMPEG" -hide_banner -loglevel error -y -sseof -0.05 -i "$OUT/band-intro.mp4" -update 1 -frames:v 1 \
  "$OUT/band-intro-poster.png"

cat > "$OUT/band-intro.timings.json" <<'JSON'
{"fps":60,"duration":4.6,"handInEnd":1.4,"bandIn":1.4,"wrapStart":1.9,"click":3.0,"settleEnd":4.6,"background":"#0A0D11","textSafeTopFraction":0.36}
JSON

echo "placeholder written to $OUT"
