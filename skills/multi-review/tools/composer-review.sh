#!/usr/bin/env bash
# Composer 2.5 (Cursor) lane for /multi-review — headless `cursor-agent`.
# WHY a wrapper (mirrors tools/gemini-review.sh): deterministic, 0 tokens per run; isolates the
#   reviewed repo from the cloud model's declared write/shell access; and on ANY failure writes a
#   single COMPOSER_ERROR: line the synthesizer detects -> the run drops to 3-of-4 lanes instead of
#   breaking. A missing Cursor Pro or a stale login must NOT take the whole skill down.
#
# Auth: needs `cursor-agent login` (browser OAuth; session stored in ~/.cursor). An API key does
#   NOT authenticate the CLI (empirically "Not logged in"). Needs Cursor Pro (Free => "No models").
# Safety: `--mode ask` is read-only (no edits — verified). We deliberately do NOT pass `--force`
#   (it would "force allow commands"; `--print` is documented to have write/shell access, so the
#   read-only guarantee must rest on `ask`, not on an undocumented ask+force interaction). If the
#   workspace is a git repo we add `--worktree` so any stray write lands in ~/.cursor/worktrees,
#   never the live tree. `--sandbox` is intentionally NOT used here: it can block the model's own
#   network call to Cursor's backend; revisit only once proven safe empirically.
#
# Usage: composer-review.sh <prompt-file> <out-file> <workspace-dir> [model]
#   Writes review text -> <out-file>. Emits ONE usage line on stderr (tokens not exposed by CLI).
set -u
PROMPT_FILE="$1"; OUT_FILE="$2"; WORKSPACE="$3"; MODEL="${4:-composer-2.5}"
TIMEOUT=900   # 15 min. perl alarm = portable timeout (macOS has no `timeout`/`gtimeout`).
RAW="${OUT_FILE%.txt}.raw"

usage () { echo "tokens=n/a model=$MODEL note=cursor-pro(request-quota,not-token-billed)" >&2; }
fail  () { echo "COMPOSER_ERROR: $1" > "$OUT_FILE"; usage; exit 0; }  # exit 0 => lane degrades, run continues

# 1. cursor-agent on PATH? (installs to ~/.local/bin — often absent in non-login/background shells)
command -v cursor-agent >/dev/null 2>&1 || fail "cursor-agent not on PATH (source ~/.zshrc or add ~/.local/bin)"

# 2. Authenticated? Else "No models" / "Not logged in" -> degrade cleanly to 3-of-4.
cursor-agent status </dev/null 2>&1 | grep -qi "logged in" || fail "not logged in / no Cursor Pro (run: cursor-agent login)"

# 3. Isolate reviewed code: a real git repo -> run in a throwaway worktree (stray writes stay in ~/.cursor).
WT=()
[ -d "$WORKSPACE/.git" ] && WT=(--worktree "mrreview-$$")

# 4. Headless run under a hard timeout. Capture stdout+stderr into RAW.
perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
  cursor-agent --print --mode ask --trust \
    --model "$MODEL" --workspace "$WORKSPACE" "${WT[@]+"${WT[@]}"}" \
    --output-format text "$(cat "$PROMPT_FILE")" > "$RAW" 2>>"$RAW"
RC=$?

# 5. Timeout? (perl alarm -> SIGALRM -> 142; some shells surface 124)
{ [ "$RC" = 142 ] || [ "$RC" = 124 ]; } && fail "timeout ${TIMEOUT}s (model=$MODEL)"

# 6. Strip ANSI/spinner escapes (cursor-agent may emit them even without a TTY in background).
sed $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' "$RAW" > "$OUT_FILE" 2>/dev/null || cp "$RAW" "$OUT_FILE"
SIZE=$(wc -c < "$OUT_FILE" 2>/dev/null | tr -d ' '); SIZE=${SIZE:-0}

# 7. Success = output actually HAS review structure. Only if it does NOT do we hunt for failure
#    signatures — otherwise a legit finding mentioning "rate limit"/"quota" trips a false COMPOSER_ERROR
#    (real verify case 2026-06-02: Composer flagged "No rate limiting" and the naive guard misfired).
if grep -qiE '\[(CRITICAL|HIGH|MEDIUM|LOW|INFO)\]|top concern|no (issues|findings|vulnerabilities)|^#{1,3} ' "$OUT_FILE"; then
  usage; exit 0  # valid review — even if it discusses rate limits / quotas inside the findings
fi
# No review structure -> diagnose why it failed (these signatures only matter on a non-review output).
[ "$SIZE" -lt 300 ] && fail "empty/too-short output (${SIZE}B, rc=$RC) — likely auth/quota/derail"
grep -qiE 'not logged in|please log in|no models available|quota exceeded' "$OUT_FILE" \
  && fail "auth/quota signature, no review produced (rc=$RC)"
fail "no review structure found (rc=$RC, ${SIZE}B) — output is not a usable review"
