#!/usr/bin/env python3
"""Convert a YouTube .vtt subtitle file into a clean timestamped transcript.

YouTube auto-captions repeat each line twice — once as settled plain text and
once as a "rolling" preview full of inline <00:00:00.480><c> tags. We keep only
the settled lines, strip tags, drop consecutive duplicates, and emit one
"(M:SS) text" block per ~sentence — the same shape as a hand-pasted transcript.

Usage: clean_vtt.py input.vtt > transcript.txt
"""
import sys, re

TS = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.\d{3}\s*-->")
INLINE = re.compile(r"<\d{2}:\d{2}:\d{2}\.\d{3}>")
TAG = re.compile(r"</?c[^>]*>|<[^>]+>")


def sec_to_mmss(s):
    m, s = divmod(int(s), 60)
    h, m = divmod(m, 60)
    return f"{h*60+m}:{s:02d}"


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: clean_vtt.py input.vtt")
    raw = open(sys.argv[1], encoding="utf-8", errors="ignore").read().splitlines()

    out = []
    cur_start = None
    last_text = ""
    for line in raw:
        m = TS.search(line)
        if m:
            h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
            cur_start = h * 3600 + mi * 60 + s
            continue
        if line.strip() in ("", "WEBVTT") or line.startswith(("Kind:", "Language:", "NOTE")):
            continue
        if INLINE.search(line):  # rolling-preview line, skip
            continue
        text = TAG.sub("", line).strip()
        if not text or text == last_text:
            continue
        last_text = text
        out.append((cur_start if cur_start is not None else 0, text))

    blocks = []
    buf, buf_start, buf_len = [], None, 0
    for start, text in out:
        if buf and (start - buf_start >= 12 or buf_len >= 200):
            blocks.append((buf_start, " ".join(buf)))
            buf, buf_start, buf_len = [], None, 0
        if buf_start is None:
            buf_start = start
        buf.append(text)
        buf_len += len(text)
    if buf:
        blocks.append((buf_start or 0, " ".join(buf)))

    for start, text in blocks:
        print(f"({sec_to_mmss(start)}) {text}")


if __name__ == "__main__":
    main()
