#!/usr/bin/env bash
# Render the Loopr onboarding band film.
#
#   ./render.sh build                 rebuild band-intro.blend from build_scene.py (with penetration check)
#   ./render.sh stills TAG [FRAMES]   reduced-size review stills -> review/TAG_fNNNN.png (default frames 60,100,150,181,276)
#   ./render.sh frames                full 1080x2340 RGBA frames -> frames/ (resumable)
#   ./render.sh encode                composite on the studio backdrop, encode HEVC, poster, timings JSON
#   ./render.sh all                   build + frames + encode
#   ./render.sh product               band product stills (transparent, 1024 px) -> band-product*.png
#
# Env: BLENDER (default blender), PCT (stills size %, default 40), SAMPLES (override Cycles samples),
#      LOOPR_SKIN for build: ghost (default) | ghost-bones | ghost-anatomy | real
#      LOOPR_BG backdrop (build and composite): pool (default) | haze | cyc, see backdrop.py
#      LOOK=anatomy  second film: builds ghost-anatomy into frames/anatomy/, encodes
#                    band-intro-anatomy.mp4 + band-intro-anatomy-poster.png, writes no timings
#                    (the app shares the main film's timings and sounds). Default SAMPLES 64.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BLENDER="${BLENDER:-blender}"
BLEND="$HERE/band-intro.blend"
FRAMES_DIR="$HERE/frames"
OUT_BASE="band-intro"
WRITE_TIMINGS=1
if [[ "${LOOK:-}" == "anatomy" ]]; then
  export LOOPR_SKIN=ghost-anatomy
  FRAMES_DIR="$HERE/frames/anatomy"
  BLEND="$FRAMES_DIR/band-intro-anatomy.blend"
  OUT_BASE="band-intro-anatomy"
  WRITE_TIMINGS=0
  SAMPLES="${SAMPLES:-64}"
elif [[ -n "${LOOK:-}" ]]; then
  echo "unknown LOOK=${LOOK}" >&2; exit 1
fi
export LOOPR_BLEND_OUT="$BLEND"
REVIEW_DIR="$HERE/review"
OUT_DIR="$ROOT/Loopr/Loopr/Resources/Onboarding"
CONTRACT="$HERE/CONTRACT.md"
FPS=60
LAST_FRAME=276

bg_hex() {
  # Background hex from the contract, fallback #07090B.
  local hex
  # Prefer the decided "Final: #RRGGBB" line; else the first hex in the Background section.
  local section; section="$(awk '/^## Background/{f=1;next} /^## /{f=0} f' "$CONTRACT")"
  hex="$(printf '%s\n' "$section" | grep -E 'Final:' | grep -oE '#[0-9A-Fa-f]{6}' | head -1 || true)"
  [[ -n "$hex" ]] || hex="$(printf '%s\n' "$section" | grep -oE '#[0-9A-Fa-f]{6}' | head -1 || true)"
  echo "${hex:-#07090B}"
}

samples_expr() {
  if [[ -n "${SAMPLES:-}" ]]; then echo "bpy.context.scene.cycles.samples=${SAMPLES};"; fi
}

gpu_expr="import bpy
p=bpy.context.preferences.addons['cycles'].preferences
p.compute_device_type='METAL'
p.get_devices()
[setattr(d,'use',True) for d in p.devices]
bpy.context.scene.cycles.device='GPU'
"

cmd_build() {
  mkdir -p "$(dirname "$BLEND")"
  "$BLENDER" -b --factory-startup --python "$HERE/build_scene.py" -- --verify 2>&1 | grep -E '^\[band\]|Error|Traceback' || true
  test -f "$BLEND"
}

composite() {
  # composite.py: straight-alpha RGBA frames onto the studio backdrop (backdrop.py), RGB out.
  # $1 = bits (16 for the encoder, 8 for posters and stills), $2 = out dir, rest = input PNGs
  local bits="$1" out="$2"; shift 2
  "$BLENDER" -b --factory-startup --python "$HERE/composite.py" -- --bits "$bits" "$out" "$@" 2>&1 \
    | grep -E 'Error|Traceback|rror:' || true
}

cmd_stills() {
  local tag="$1"; shift || true
  local frames="${1:-60,100,150,181,276}"
  local pct="${PCT:-40}"
  mkdir -p "$REVIEW_DIR" "$HERE/.stills"
  rm -f "$HERE/.stills/${tag}_"*
  "$BLENDER" -b "$BLEND" --python-expr "$gpu_expr
bpy.context.scene.render.resolution_percentage=${pct}
$(samples_expr)" -o "$HERE/.stills/${tag}_f####" -F PNG -f "$frames" 2>&1 | grep -E 'Saved|Error|Time:' || true
  composite 8 "$REVIEW_DIR" "$HERE/.stills/${tag}_f"*.png
  for f in "$HERE/.stills/${tag}_f"*.png; do echo "review: $REVIEW_DIR/$(basename "$f")"; done
}

cmd_frames() {
  mkdir -p "$FRAMES_DIR"
  # frames are resumable: a stale set from an older build would be kept, so refuse to mix
  if [[ -f "$FRAMES_DIR/.blend-stamp" ]] && ! cmp -s "$FRAMES_DIR/.blend-stamp" <(stat -f%m "$BLEND"); then
    echo "frames in $FRAMES_DIR come from an older build; delete them first" >&2; exit 1
  fi
  stat -f%m "$BLEND" > "$FRAMES_DIR/.blend-stamp"
  local start=$SECONDS
  "$BLENDER" -b "$BLEND" --python-expr "$gpu_expr
bpy.context.scene.render.use_overwrite=False
bpy.context.scene.render.use_placeholder=True
$(samples_expr)" -o "$FRAMES_DIR/f_####" -F PNG -a 2>&1 | grep -E 'Saved|Error|Time:' || true
  echo "render wall time: $((SECONDS - start)) s"
  local n; n="$(ls "$FRAMES_DIR"/f_????.png | wc -l | tr -d ' ')"
  [[ "$n" == "$LAST_FRAME" ]] || { echo "expected $LAST_FRAME frames, found $n" >&2; exit 1; }
}

cmd_encode() {
  mkdir -p "$OUT_DIR"
  local hex; hex="$(bg_hex)"
  echo "background $hex"
  local mp4="$OUT_DIR/$OUT_BASE.mp4"
  local comp="$FRAMES_DIR/comp"
  rm -rf "$comp"; mkdir -p "$comp"
  composite 16 "$comp" "$FRAMES_DIR"/f_????.png
  local crf="${CRF:-14}"
  while :; do
    ffmpeg -v error -y -framerate $FPS -start_number 1 -i "$comp/f_%04d.png" \
      -vf "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p10le" \
      -frames:v $LAST_FRAME -an -c:v libx265 -preset slow -tune grain -crf "$crf" -pix_fmt yuv420p10le \
      -x265-params "log-level=error:aq-mode=3:colorprim=bt709:transfer=iec61966-2-1:colormatrix=bt709:range=limited" \
      -color_primaries bt709 -color_trc iec61966-2-1 -colorspace bt709 -color_range tv \
      -tag:v hvc1 -movflags +faststart "$mp4"
    local size; size="$(stat -f%z "$mp4")"
    echo "crf $crf -> $size bytes"
    if (( size <= 8000000 )); then break; fi
    crf=$((crf + 1))
  done
  local last; last="$FRAMES_DIR/f_$(printf %04d $LAST_FRAME).png"
  composite 8 "$comp/poster" "$last"
  mv "$comp/poster/$(basename "$last")" "$OUT_DIR/$OUT_BASE-poster.png"
  echo "poster $OUT_DIR/$OUT_BASE-poster.png"
  if (( ! WRITE_TIMINGS )); then echo "timings: not written for $OUT_BASE (shares band-intro.timings.json)"; return; fi
  # textSafeTopFraction: rows above the first row where the last frame's alpha reaches 1/255
  local safe
  safe="$("$BLENDER" -b --factory-startup --python-expr "
import OpenImageIO as oiio, numpy as np
a = oiio.ImageInput.open('$FRAMES_DIR/f_$(printf %04d $LAST_FRAME).png').read_image(format='float')[:, :, 3]
rows = np.where(a.max(axis=1) >= 1.0 / 255.0)[0]
print('SAFE=%.3f' % (np.floor(rows[0] / a.shape[0] * 1000) / 1000))
" 2>/dev/null | sed -n 's/^SAFE=//p')"
  echo "textSafeTopFraction $safe (measured on the last frame)"
  local tj="$OUT_DIR/band-intro.timings.json"
  local want; want="$(printf '{"fps":60,"duration":4.6,"handInEnd":1.4,"bandIn":1.4,"wrapStart":1.9,"click":3.0,"settleEnd":4.6,"background":"%s","textSafeTopFraction":%s}' "$hex" "$safe")"
  if [[ -f "$tj" ]]; then
    # The app is built against the committed file: keep it byte-identical. The film only has to keep
    # the text area clear, so a measured fraction at or below the subject's top is fine.
    local have; have="$(sed -n 's/.*"textSafeTopFraction":\([0-9.]*\).*/\1/p' "$tj")"
    if ! awk -v m="$safe" -v h="$have" 'BEGIN { exit !(m + 0 >= h + 0) }'; then
      echo "the last frame reaches into the text area: textSafeTopFraction $safe < $have in $tj" >&2; exit 1
    fi
    [[ "$(sed 's/"textSafeTopFraction":[0-9.]*//' "$tj")" == "$(printf '%s\n' "$want" | sed 's/"textSafeTopFraction":[0-9.]*//')" ]] \
      || { echo "$tj differs from the beats in render.sh; not touching it" >&2; exit 1; }
    echo "timings unchanged: $(cat "$tj")"
  else
    printf '%s\n' "$want" > "$tj"
    cat "$tj"
  fi
}

cmd_product() {
  # product_stills.py: the closed band alone, studio lit, transparent; pngquant keeps each under ~400 KB
  local tmp="$HERE/.stills/product"
  rm -rf "$tmp"; mkdir -p "$tmp"
  "$BLENDER" -b "$BLEND" --python "$HERE/product_stills.py" -- "$tmp" product pairing tap \
    --samples "${SAMPLES:-256}" 2>&1 | grep -E '\[stills\]|Error|Traceback' || true
  for v in product pairing tap; do
    local out="$OUT_DIR/band-product-$v.png"
    [[ "$v" == "product" ]] && out="$OUT_DIR/band-product.png"
    pngquant --force --quality 80-98 --speed 1 --strip --output "$out" "$tmp/band-$v.png"
    echo "product $out $(stat -f%z "$out") bytes"
  done
}

case "${1:-}" in
  build) cmd_build ;;
  stills) shift; cmd_stills "$@" ;;
  frames) cmd_frames ;;
  encode) cmd_encode ;;
  all) cmd_build; cmd_frames; cmd_encode ;;
  product) cmd_product ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
