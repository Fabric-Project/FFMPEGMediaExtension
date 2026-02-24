#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Generate synthetic test footage for container/codec validation.

Usage:
  $(basename "$0") [options]

Options:
  --outdir DIR        Output directory (default: ./TestMedia)
  --duration SEC      Clip duration in seconds (default: 5)
  --fps FPS           Video frame rate (default: 30)
  --size WxH          Frame size (default: 1920x1080)
  --start-frame N     Overlay frame count start (default: 1)
  --timecode TC       Start timecode HH:MM:SS:FF (default: 01:00:00:00)
  --overwrite         Overwrite existing files
  -h, --help          Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --duration 3 --size 1280x720 --outdir /tmp/libav-tests --overwrite
USAGE
}

OUTDIR="./TestMedia"
DURATION="5"
FPS="30"
SIZE="1920x1080"
START_FRAME="1"
TIMECODE="01:00:00:00"
OVERWRITE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir)
      OUTDIR="$2"; shift 2 ;;
    --duration)
      DURATION="$2"; shift 2 ;;
    --fps)
      FPS="$2"; shift 2 ;;
    --size)
      SIZE="$2"; shift 2 ;;
    --start-frame)
      START_FRAME="$2"; shift 2 ;;
    --timecode)
      TIMECODE="$2"; shift 2 ;;
    --overwrite)
      OVERWRITE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found in PATH" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

font_candidates=(
  "./Inconsolata-Regular.ttf"
  "/System/Library/Fonts/Supplemental/Courier New.ttf"
  "/System/Library/Fonts/SFNSMono.ttf"
  "/Library/Fonts/Arial Unicode.ttf"
)

FONTFILE=""
for f in "${font_candidates[@]}"; do
  if [[ -f "$f" ]]; then
    FONTFILE="$f"
    break
  fi
done

if [[ -n "$FONTFILE" ]]; then
  DRAW_TEXT="drawtext=text='Frame\\: %{frame_num}':start_number=${START_FRAME}:x=(w-tw)/2:y=h-(2*lh):fontfile='${FONTFILE}':fontsize=40:fontcolor=white:alpha=0.7:box=1:boxcolor=black@0.45:boxborderw=8,drawtext=text='TC':x=(w-tw)/2:y=(lh):fontfile='${FONTFILE}':fontsize=40:fontcolor=white:timecode='${TIMECODE//:/\\:}':timecode_rate=${FPS}"
else
  echo "No local font file found, using bare smptebars+sine without drawtext overlays"
  DRAW_TEXT="null"
fi

OVERWRITE_FLAG="-n"
if [[ "$OVERWRITE" -eq 1 ]]; then
  OVERWRITE_FLAG="-y"
fi

SIZE_TAG="${SIZE//x/_}"

run_ffmpeg() {
  local output="$1"
  shift
  echo "Generating: $output"
  ffmpeg -hide_banner -loglevel warning \
    -f lavfi -i "smptebars=size=${SIZE}:rate=${FPS}:duration=${DURATION}" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${DURATION}" \
    -vf "$DRAW_TEXT" \
    "$@" \
    -shortest \
    -t "$DURATION" \
    $OVERWRITE_FLAG \
    "$OUTDIR/$output"
}

# MKV/H.264 + AAC
run_ffmpeg "baseline_${SIZE_TAG}_${FPS}fps_h264_aac.mkv" \
  -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p \
  -c:a aac -b:a 192k

# MKV/H.264 all-I + AAC (no B/P frames; PTS should match DTS for video samples)
run_ffmpeg "baseline_${SIZE_TAG}_${FPS}fps_h264_alli_aac.mkv" \
  -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p \
  -g 1 -keyint_min 1 -bf 0 -sc_threshold 0 \
  -c:a aac -b:a 192k

# MKV/VP9 + Opus
run_ffmpeg "baseline_${SIZE_TAG}_${FPS}fps_vp9_opus.mkv" \
  -c:v libvpx-vp9 -row-mt 1 -crf 33 -b:v 0 -pix_fmt yuv420p \
  -c:a libopus -b:a 128k

# AVI/MPEG-4 in XVID style + MP3
run_ffmpeg "baseline_${SIZE_TAG}_${FPS}fps_xvid_mp3.avi" \
  -c:v mpeg4 -q:v 5 -vtag XVID \
  -c:a libmp3lame -b:a 192k

# AVI/MPEG-4 in DIVX style + MP3
run_ffmpeg "baseline_${SIZE_TAG}_${FPS}fps_divx_mp3.avi" \
  -c:v mpeg4 -q:v 5 -vtag DIVX \
  -c:a libmp3lame -b:a 192k

# ASF/WMV2 + WMA2 (for .wmv workflows)
run_ffmpeg "baseline_${SIZE_TAG}_${FPS}fps_wmv2_wmav2.wmv" \
  -c:v wmv2 -b:v 4M \
  -c:a wmav2 -b:a 192k

echo ""
echo "Done. Files written to: $OUTDIR"
ls -1 "$OUTDIR"
