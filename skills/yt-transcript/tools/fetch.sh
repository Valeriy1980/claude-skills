#!/bin/bash
# yt-transcript: fetch YouTube subtitles → clean timestamped transcript file.
# Usage: fetch.sh <youtube-url> [out-dir]
# Prints the final .txt path to stdout; progress + status go to stderr.
set -euo pipefail

URL="${1:?usage: fetch.sh <youtube-url> [out-dir]}"
OUT="${2:-$HOME/Downloads/yt-transcripts}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT"

# Single yt-dlp run (fewer requests = less 429): write subs AND print id+title.
# --no-simulate forces sub writing despite --print; --skip-download skips video.
# Lang priority: Ukrainian, Russian, English (+ auto tracks). Retry/sleep vs 429.
INFO="$(COOKIES=${YT_COOKIES_FROM_BROWSER:-}
  yt-dlp --no-warnings --no-simulate --skip-download \
    --write-subs --write-auto-subs \
    --sub-langs "uk,ru,en,en-orig,a.en,a.uk,a.ru" --sub-format vtt \
    --retries 10 --extractor-retries 5 --sleep-requests 1.5 --sleep-subtitles 3 \
    ${COOKIES:+--cookies-from-browser "$COOKIES"} \
    --print "%(id)s	%(title)s" \
    -o "$OUT/%(id)s.%(ext)s" "$URL")" || {
      echo "ERROR: yt-dlp failed (often HTTP 429 rate-limit — retry later, or set YT_COOKIES_FROM_BROWSER=chrome)" >&2; exit 1; }

ID="${INFO%%	*}"; TITLE="${INFO#*	}"
[ -z "$ID" ] && { echo "ERROR: cannot resolve video id" >&2; exit 1; }

# Pick best available vtt by lang priority.
VTT=""
for lang in uk ru en en-orig; do
  for f in "$OUT/$ID.$lang.vtt" "$OUT/$ID."*"$lang"*.vtt; do
    [ -f "$f" ] && { VTT="$f"; break 2; }
  done
done
[ -z "$VTT" ] && VTT="$(ls -1 "$OUT/$ID."*.vtt 2>/dev/null | head -1 || true)"
[ -z "$VTT" ] && { echo "ERROR: no subtitles available for $ID (video may have none)" >&2; exit 2; }

TXT="$OUT/$ID.transcript.txt"
{
  echo "# $TITLE"
  echo "# $URL"
  echo "# source subtitles: $(basename "$VTT")"
  echo
  python3 "$HERE/clean_vtt.py" "$VTT"
} > "$TXT"

echo "$TXT"
echo "OK: $(grep -c '^(' "$TXT" || echo 0) timestamped blocks → $TXT" >&2
