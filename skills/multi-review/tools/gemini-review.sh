#!/usr/bin/env bash
# Gemini lane for /multi-review via REST generateContent (no CLI agent -> no tool-derail, no @-expansion, cwd-independent).
# WHY: headless `gemini -p` runs a tool-enabled agent that parses @-tokens out of the reviewed code
#      (Deno imports std@0.177.0/..., npm @scope/pkg@ver) as file paths and stat()s them -> ENAMETOOLONG /
#      "Falling back to GrepTool" noise -> derailed output with zero findings. REST has no agent, no @-expansion.
# Usage: gemini-review.sh <prompt-file> <out-file> [model]
# Writes review text -> <out-file>; raw JSON -> <out-file:.txt->.raw.json> (for token accounting);
# emits ONE machine-readable usage line on stderr: in=.. out=.. think=.. total=.. model=..
set -u
PROMPT_FILE="$1"; OUT_FILE="$2"; MODEL="${3:-gemini-3.1-pro-preview}"
FALLBACK_MODEL="gemini-3.6-flash"           # verified live 2026-07-26 (ListModels + generateContent 200); $1.50 in / $7.50 out, flat
RAW="${OUT_FILE%.txt}.raw.json"
BODY="${OUT_FILE%.txt}.body.json"
[ -n "${GEMINI_API_KEY:-}" ] || { echo "GEMINI_ERROR: GEMINI_API_KEY not set (run: source ~/.zshrc)" > "$OUT_FILE"; exit 1; }

# Build JSON body with python json.dumps so the multiline prompt (backticks, quotes, @-tokens, $VAR, newlines)
# is embedded SAFELY as a JSON string field -- never interpolated into a shell command.
python3 -c 'import json,sys; print(json.dumps({"contents":[{"parts":[{"text":open(sys.argv[1]).read()}]}],"generationConfig":{"temperature":0}}))' "$PROMPT_FILE" > "$BODY"

_call () {  # $1=model -> writes RAW, echoes HTTP code. perl alarm = portable timeout (macOS has no `timeout`/`gtimeout`).
  perl -e 'alarm shift; exec @ARGV' 240 curl -sS -o "$RAW" -w '%{http_code}' \
    "https://generativelanguage.googleapis.com/v1beta/models/$1:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" -H "Content-Type: application/json" \
    -X POST -d "@$BODY"
}

USED="$MODEL"; CODE="$(_call "$MODEL")"
if [ "$CODE" != "200" ]; then
  echo "[gemini-review] $MODEL -> HTTP $CODE, retrying $FALLBACK_MODEL" >&2
  USED="$FALLBACK_MODEL"; CODE="$(_call "$FALLBACK_MODEL")"
fi

# Parse: strict=False (model emits raw control chars/newlines inside the text string). Never crash on
# no-candidates / SAFETY block / error body -> always write a GEMINI_ERROR: line the synthesizer can detect.
python3 - "$RAW" "$OUT_FILE" "$USED" "$CODE" <<'PYEOF'
import json, sys
raw_path, out_path, used, code = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def usage(i=0,o=0,th=0,tot=0):
    print(f"in={i} out={o+th} think={th} total={tot} model={used}", file=sys.stderr)
try:
    d = json.loads(open(raw_path).read(), strict=False)
except Exception as e:
    open(out_path,"w").write(f"GEMINI_ERROR: unparseable response (HTTP {code}): {e}\n"); usage(); sys.exit(0)
if isinstance(d, dict) and d.get("error"):
    open(out_path,"w").write(f"GEMINI_ERROR: HTTP {code} {d['error'].get('status')}: {d['error'].get('message','')}\n"); usage(); sys.exit(0)
cands = d.get("candidates") or []
if not cands or not cands[0].get("content",{}).get("parts"):
    fr = cands[0].get("finishReason") if cands else None
    br = d.get("promptFeedback",{}).get("blockReason")
    open(out_path,"w").write(f"GEMINI_ERROR: no content (HTTP {code} finishReason={fr} blockReason={br})\n"); usage(); sys.exit(0)
text = "".join(p.get("text","") for p in cands[0]["content"]["parts"])
open(out_path,"w").write(text)
u = d.get("usageMetadata", {})
# OUTPUT billed = candidatesTokenCount + thoughtsTokenCount (thinking tokens bill as output);
# verified: cand+thoughts == totalTokenCount - promptTokenCount.
usage(u.get("promptTokenCount",0) or 0, u.get("candidatesTokenCount",0) or 0, u.get("thoughtsTokenCount",0) or 0, u.get("totalTokenCount",0) or 0)
PYEOF
