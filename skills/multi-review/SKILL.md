---
name: multi-review
description: Триангуляція критичного код- і security-рев'ю через 4 різні вендори (Claude Opus 5 + Codex GPT-5.6 Sol + Gemini 3.1 Pro + Cursor Composer 2.5). Бери, коли сліпа пляма однієї моделі коштує дорого — security-аудит перед продом, зміни в auth / платежах / міграціях, архітектурна розвилка на 6+ місяців, застряг 2+ рази, валідація чужого звіту — або на прямий /multi-review. Не для звичайного код-рев'ю — там /ce-review.
---

# /multi-review — рев'ю чотирма вендорами

**Склад lane-ів (перевірено 2026-07-26):** Claude Opus 5 · Codex CLI 0.145 на `gpt-5.6-sol` (reasoning effort `ultra` — з `~/.codex/config.toml`) · `gemini-3.1-pro-preview` (fallback `gemini-3.6-flash`) · Cursor `composer-2.5`. Версії моделей гниють швидко — перед прогоном звіряй живі назви, а не цей рядок: `cursor-agent models`, `codex --version`, ListModels у Gemini API.

Триангуляційний рев'ю через 4 різні моделі різних провайдерів. Виправдовує себе у тих рідкісних випадках коли single-model blind spots можуть коштувати дорого (security дірки у production, помилка архітектури з тривалим імпактом).

**Чому взагалі 4:** власні записи про крос-провайдерну перевірку — Codex-lane знайшов CRITICAL free-pickup bypass, який Claude і Gemini пропустили. Без крос-вендорності баг пішов би у прод.

> 🔧 **Gemini lane = REST, не CLI** (фікс 2026-05-31). Headless `gemini -p` запускає агента з інструментами, який ламається на `@`-токенах у коді — деталі у Phase 2 Lane 3 і Failure mode #7. Виклик іде через `tools/gemini-review.sh`.

---

## When to use

✅ **Так:**
- Security audit перед client handoff / production launch
- Зміни у auth / payments / migrations / RLS
- Архітектурні розвилки з 6+ місяців наслідками
- Production debugging що блокує користувачів І Claude застряг 2+ разів
- Post-marathon аудит (багато commits за день, потрібен незалежний погляд)
- Валідувати звіт одного інструмента (Cursor Bugbot, single-model audit) рештою вендорів — підтвердити його знахідки, відсіяти хибні й знайти, що він пропустив

❌ **Ні:**
- Прості зміни (1-3 файли, очевидна логіка) → роби сам
- UI-only задачі → `/frontend-design`
- Plan / brainstorm → `/ce-brainstorm`, `/ce-plan`
- Звичайний code-review → `/ce-review` (17 персон на Sonnet, дешевше, достатньо для більшості)
- Якщо Claude ще сам не зрозумів задачу — спочатку розібратися

---

## Input

Один з варіантів аргументу:

| Тип scope | Як виглядає аргумент | Приклад |
|---|---|---|
| **PR** | `#123` або URL до PR | `/multi-review #45` |
| **Branch** | назва гілки (без `..`) | `/multi-review feature/auth-redesign` |
| **Commit range** | `from..to` | `/multi-review main..HEAD` |
| **File** | відносний шлях до файлу | `/multi-review src/app/api/payment/route.ts` |
| **Directory** | відносний шлях до теки | `/multi-review src/features/payment/` |
| **Document** | шлях до .md / .txt | `/multi-review docs/plans/2026-05-21-001-...-plan.md` |

**Якщо аргумент відсутній:** запитати у користувача що рев'юити. Запропонувати 2-3 sensible defaults (наприклад «останній diff на гілці», «весь src/`<останньо змінена тека>`/»).

---

## Workflow

### Phase 1: Parse scope + prepare context

1. **Визначити тип scope** через евристики (по порядку):
   - Починається з `#` або pure digits → PR number
   - Містить `..` → commit range
   - Існує як файл/тека (`test -e`) → file/directory
   - Інакше → branch name (валідація `git rev-parse --verify`)

2. **Зібрати контекст** залежно від типу:
   - PR: `gh pr view <num> --json title,body,files` + `gh pr diff <num>`
   - Commit range: `git diff <range>` + `git log --oneline <range>`
   - Branch: `git diff main...<branch>` + список файлів
   - File / dir: `cat` або `find ... | xargs cat` для усіх .ts/.tsx/.js/.py/.rb
   - Document: `cat <file>`

3. **Detect project type** для output location:
   - `test -d .git` → output у `<repo-root>/docs/code-reviews/`
   - не git → запитати куди (default `~/code-reviews/`)

4. **Estimate token count** (rough: chars / 3.5 — консервативна оцінка для коду). Якщо >150K — попередити користувача:
   - "Scope = ~Xk tokens. Gemini 3.1 Pro >200K перейде у tier $4 вхід / $18 вихід per M (вхід ×2, вихід ×1.5). Codex може hit context limit. Продовжити чи розбити?"

5. **Build PROMPT_BASE** (єдиний template для всіх 4 reviewer-ів):

```text
You are an expert code reviewer performing a thorough security and quality audit.

SCOPE: <scope description, e.g. "PR #45 — Add OAuth flow to admin panel">

FILES TO REVIEW:
<list of files with paths>

CONTEXT:
<full file contents OR diff, depending on scope type>

INSTRUCTIONS:
1. Find ALL issues at every severity level (CRITICAL, HIGH, MEDIUM, LOW, INFO).
2. For each finding, output:
   - **[SEVERITY] Title** (one line)
   - **File:** path:line
   - **Description:** 1-2 sentences
   - **Attack scenario / Impact:** 2-3 sentences (be concrete)
   - **Suggested fix:** code snippet or precise steps
3. Be thorough. Even style/maintainability concerns at LOW.
4. Reference OWASP Top 10 / STRIDE / CWE where relevant.
5. Group findings by severity (CRITICAL first).
6. End with a one-paragraph "Top concern" summary.

DO NOT:
- Write "looks good" — find issues.
- Speculate without evidence ("could maybe in theory" — only with code reference).
- Pad with generic best-practice lectures — be specific to THIS code.
```

### Phase 2: Parallel deploy (4 agents in background)

**КРОК 2.0 — Записати PROMPT_BASE у файли.** Довгі промпти з лапками / backticks / code blocks ламають shell escaping якщо передавати через `exec "<long-prompt>"`. Тому ПЕРШ ніж запускати агентів — запиши кожен фінальний промпт (PROMPT_BASE + FOCUS_HINT для конкретного агента) у файл:

```bash
TS=$(date +%s)
cat > /tmp/multi-review-prompt-claude-$TS.txt <<'PROMPT_EOF'
<PROMPT_BASE>

FOCUS_HINT: Take adversarial stance. Actively construct attack scenarios. Assume bad actor with knowledge of system internals.
PROMPT_EOF

cat > /tmp/multi-review-prompt-codex-$TS.txt <<'PROMPT_EOF'
<PROMPT_BASE>

FOCUS_HINT: Focus on architectural patterns, business logic bypasses, design issues. Check for impedance mismatches between layers.
PROMPT_EOF

cat > /tmp/multi-review-prompt-gemini-$TS.txt <<'PROMPT_EOF'
<PROMPT_BASE>

FOCUS_HINT: Cover breadth. Find issues across all files quickly. Calibrate severity carefully — do not inflate.
PROMPT_EOF

cat > /tmp/multi-review-prompt-composer-$TS.txt <<'PROMPT_EOF'
<PROMPT_BASE>

FOCUS_HINT: Architectural correctness, business-logic bypasses, fail-open paths (external API/Sheets fails -> validation silently skipped), sister-endpoint data leaks, DoS amplification, idempotency across instances. (Composer's strengths. Known blind spot: sometimes misses pubkey/key-refetch DoS — so it complements, does not replace, the others.)
PROMPT_EOF
```

Запам'ятай `$TS` — він піде у вихідні файли всіх 4 агентів для трейсу.

**КРОК 2.1 — Запустити усі 4 у ОДНОМУ message** через окремі tool calls (single message → parallel execution):

**Lane 1 — Claude Opus 5 (adversarial focus):**
```
Agent tool:
  description: "Adversarial multi-review lane (Claude)"
  subagent_type: "general-purpose"
  prompt: <content of /tmp/multi-review-prompt-claude-$TS.txt — read file inline і встав сюди як string>
  run_in_background: true
```

Зауваж: Agent tool `prompt` параметр приймає string inline (не file path), тому прочитай файл і встав його зміст у параметр. Чому `general-purpose`: має повний tool-set (read files, bash, web) на випадок якщо моделі потрібно щось додатково перевірити у коді.

**Lane 2 — Codex `gpt-5.6-sol` (architectural focus):**
```
Bash tool:
  command: cat /tmp/multi-review-prompt-codex-$TS.txt | codex exec --skip-git-repo-check "$(cat)" > /tmp/multi-review-codex-$TS.txt 2>&1
  run_in_background: true
```

Модель береться з `~/.codex/config.toml` (`model = "gpt-5.6-sol"`). Слабший тир (Terra / Luna) саме тут не бери — цей lane тримаємо за обходи бізнес-логіки, а це найважча частина рев'ю; явно перебити можна прапорцем `-m`.

Чому `cat | codex exec "$(cat)"`: codex inheritає stdin від pipe (інакше може зависнути ~30 хв чекаючи stdin — реальний кейс), а `"$(cat)"` робить безпечну передачу багаторядкового промпту як єдиний аргумент.

**Lane 3 — Gemini 3.1 Pro (breadth focus) — через REST `generateContent`, НЕ через CLI:**
```
Bash tool (run_in_background: true):
  command: source ~/.zshrc && bash ~/.claude/skills/multi-review/tools/gemini-review.sh \
             /tmp/multi-review-prompt-gemini-$TS.txt \
             /tmp/multi-review-gemini-$TS.txt \
             gemini-3.1-pro-preview \
           2> /tmp/multi-review-gemini-usage-$TS.txt
```

**Lane 4 — Cursor Composer 2.5 (architectural + business-logic focus) — через `cursor-agent` headless, обгортка `tools/composer-review.sh`:**
```
Bash tool (run_in_background: true):
  command: source ~/.zshrc && bash ~/.claude/skills/multi-review/tools/composer-review.sh \
             /tmp/multi-review-prompt-composer-$TS.txt \
             /tmp/multi-review-composer-$TS.txt \
             <WORKSPACE — тека репо, або чиста копія scope> \
             composer-2.5 \
           2> /tmp/multi-review-composer-usage-$TS.txt
```

**Композиція 4 lane:** Claude (Agent tool) + Codex + Gemini + Composer (кожен Bash `run_in_background`) — усі в ОДНОМУ message → справжній паралелізм. Кілька застережень саме до Composer-lane:
- **Потребує Cursor Pro + `cursor-agent login`** (сесія в `~/.cursor`; API-ключ НЕ автентифікує CLI — емпірично «Not logged in»). Недоступний → обгортка пише `COMPOSER_ERROR:` → синтез **на 3 з 4** (graceful degrade, не блокер).
- **`<WORKSPACE>`** = тека репо. Обгортка сама ізолює git-репо через `--worktree` (будь-який випадковий запис іде у `~/.cursor/worktrees`, не у живе дерево). Безпека read-only тримається на `--mode ask` (БЕЗ `--force`).
- **Composer токенів не віддає** (CLI text) → у Cost це «Cursor Pro: request-quota, не токени».

**Чому НЕ `gemini -p` (root cause минулих фейлів):** headless CLI запускає повноцінного агента з інструментами навіть у `-p` режимі. Він чіпляє `@`-токени з рев'юеного коду (Deno-імпорти `std@0.177.0/...`, npm `@scope/pkg@ver`) як файлові шляхи, робить по них `stat`/grep і ламає вивід: `Ripgrep is not available. Falling back to GrepTool` / `Error stating path` / `ENAMETOOLONG` → замість рев'ю — відлуння коду без знахідок. Жоден CLI-прапорець НЕ лікує надійно (`-o json`, `--approval-mode plan`, `--policy deny`, `tools.core:[]` — усі емпірично спростовані 2026-05-31: `@`-резолюція й `stat` відбуваються ВИЩЕ за tool-allowlist). REST `generateContent` — чистий one-shot без агента, без `@`-expansion, не залежить від cwd.

Обгортка `tools/gemini-review.sh` (детермінований код, 0 токенів на кожному запуску): будує JSON-тіло через `python json.dumps` (промпт вкладається у JSON-поле, тому shell-escaping тут НЕ діє — на відміну від Codex/Claude lane-ів), кличе REST під `perl`-alarm таймаутом 240с (на macOS нема `timeout`), на будь-який не-200 АВТОМАТИЧНО ретраїть на `gemini-3.6-flash`, безпечно парсить відповідь (`strict=False` — модель емітить сирі переноси рядків), пише рев'ю у out-файл, а рядок токенів `in=.. out=.. think=.. total=..` — у stderr. Hedge від deprecation: можна передати alias `gemini-pro-latest` як 3-й аргумент (сьогодні резолвиться у `gemini-3.1-pro-preview`).

**КРОК 2.2 — Capture task IDs.** Усі 4 tool calls повернуть background task IDs. Збережи їх — потрібні для:
- Очікування завершення (Phase 3)
- TaskStop якщо один lane завис (>30 хв) (Failure mode #1)

### Phase 3: Wait for all 4 to complete

❌ **НЕ polling.** Harness сам пінгне коли кожен закінчиться через background-task-completed notifications.

✅ Просто чекати notification messages про завершення background tasks. У 95% випадків — за 5-15 хв wall-clock.

**Edge case — один з 4 fails / hangs > 30 min:**
- Stop hung task через TaskStop з збереженим task_id
- Продовжити з 3 з 4 results
- У звіт додати warning: "Lane X failed або hung — synthesis базується на 3 з 4 lanes"
- Gemini-specific: якщо out-файл починається з `GEMINI_ERROR:` — lane впав → 3 з 4.
- Composer-specific: якщо out-файл починається з `COMPOSER_ERROR:` (не залогінений / нема Cursor Pro / timeout / порожньо) → lane впав → 3 з 4. Це найімовірніший degrade — Composer єдиний потребує окремого Cursor Pro.

### Phase 4: Read all 4 outputs

Lane-и Codex/Gemini/Composer пишуть у файли з тим самим `$TS` (Claude повертається через notification, не файл):

```bash
# Читай СТРОГО за поточним $TS — без `ls -t | head` (інакше підхопиш файл попереднього прогону)
CODEX_OUT="/tmp/multi-review-codex-$TS.txt"
GEMINI_OUT="/tmp/multi-review-gemini-$TS.txt"
COMPOSER_OUT="/tmp/multi-review-composer-$TS.txt"
```

**Lane 1 (Claude через Agent tool):** результат повертається через notification з повним output у `result` field task'а. Зчитай через TaskOutput tool якщо потрібен повний trace, або просто з content `result` поля notification.

**Lane 2 (Codex):** `cat $CODEX_OUT`. Tail містить usage stats — `tokens used: <n>`.

**Lane 3 (Gemini):** `cat $GEMINI_OUT` (пише обгортка). Якщо файл починається з `GEMINI_ERROR:` — lane впав, продовжити з 3 з 4. Сире JSON для форензики — у `$GEMINI_OUT` з заміною `.txt`→`.raw.json`.

**Lane 4 (Composer):** `cat $COMPOSER_OUT` (пише обгортка `composer-review.sh`). Якщо файл починається з `COMPOSER_ERROR:` — lane впав (не залогінений / нема Cursor Pro / timeout / безструктурний вивід), продовжити з 3 з 4. Сирий вивід cursor-agent (форензика) — у `$COMPOSER_OUT` з заміною `.txt`→`.raw`.

**Token accounting:**
- Claude: з task notification metadata (`total_tokens` поле)
- Codex: парсити `tokens used:` з останніх рядків $CODEX_OUT
- Gemini: рядок `in=.. out=.. think=.. total=..` з usage-файлу `/tmp/multi-review-gemini-usage-$TS.txt` (або з `.raw.json` → `usageMetadata`). ⚠️ Це **thinking-модель**: вихідні токени для cost = `candidatesTokenCount + thoughtsTokenCount` (= `totalTokenCount − promptTokenCount`). НЕ бери лише `candidatesTokenCount` — недооцінка вихідних у 2-6×, бо reasoning-токени білляться як OUTPUT.
- Composer: токенів CLI **не віддає** — usage-рядок лише `tokens=n/a model=composer-2.5 note=cursor-pro(...)`. У Cost це «Cursor Pro: request-quota, не токени» — **НЕ $0**: ліміт по кількості запитів/місяць, великий аудит може його вичерпати (тоді lane поверне `COMPOSER_ERROR` quota → 3 з 4).

### Phase 5: Synthesize

Це **найважливіша фаза**. Claude через цей чат читає всі 4 звіти (3, якщо якийсь lane дав ERROR) і будує:

1. **Унікальний каталог findings.** Matching algorithm:
   - Normalize titles: lowercase, strip punctuation, remove stop words (the, a, an, of, in)
   - Two findings MATCH якщо:
     - Same file (path рівні після нормалізації) AND
     - Line numbers within ±2 (same logical location) AND
     - Title token-overlap ≥3 meaningful words OR (≥50% of shorter title's tokens)
   - При match: merge у one entry з voting count++
   - При mismatch: окрема стрічка

2. **Voting column** — для кожного finding: ✅/❌ за кожним з 4 lane. Консенсус тепер має градації: **4/4** (найсильніший), **3/4**, **2/4**, **1/4** — не зливай їх в одну купу, сила сигналу різна.

3. **Severity calibration** — якщо lane дали різну severity, беремо MAX ("fail safe"). АЛЕ з 4 джерел зростає шанс, що ОДИН завищить, а MAX це механічно підхопить. Тому: якщо найвищу severity тримає **лише 1 lane** і вона на **2+ рівні вища** за решту — НЕ став її тихо у фінал, винеси у Disagreements з позначкою «single-lane max — verify». Будь-яке розходження >1 рівень — у Disagreements завжди, навіть якщо resolved.

4. **Disagreements section** — НАЙЦІННІШЕ. Виокремити:
   - **1/4 findings** — знайшов лише один lane. Унікальний insight АБО шум — потрібна ручна оцінка. ⚠️ З 4 генераторів таких рядків більше; НЕ підписуй автоматично «high value» — кожен судиться окремо (lane мають задокументовані сліпі плями: напр. Composer часто пропускає pubkey/key-refetch DoS).
   - Findings де severity розходиться на 2+ рівні (blind-spot калібрування АБО single-lane завищення)
   - Прямі суперечності («Reviewer A каже фіксити Х → B каже залишити»)
   - ⚡ **Live-verify фактичних розбіжностей.** Якщо суперечка про **перевірюваний факт** (чи ловить regex `X`, чи libpq бере правий `@`, чи grep бачить `COMMIT\n;`) — НЕ розв'язуй голосуванням, перевір наживо одним мінімальним тестом. Реальний кейс 2026-06-03: було 3 проти 1, але навіть більшість могла помилятись — вирішила жива перевірка (Claude впевнено помилявся на `COMMIT\n;`, решта мали рацію). Голосування — для суджень; факти — для тесту.

5. **Batched fix plan** — групи фіксів за логічними кластерами (e.g. «auth layer: 3 issues», «input validation: 2 issues», «error handling: 4 issues»).

**Edge case — всі reviewer дали 0 findings:**
- Не пропускай Phase 6. Напиши «clean review» звіт зі структурою:
  - Cost & Performance (як завжди)
  - Summary: "All N reviewers returned 0 findings. Code appears clean within review scope."
  - Section "What was checked" — список файлів з підтвердженням що scope був повноцінний (не помилково порожній)
  - Recommendation: "Якщо це pre-launch — все OK. Якщо це post-marathon або post-incident — варто перевірити чи scope охопив реальний risk surface."

### Phase 6: Write synthesis report

**Output slug derivation:**
- PR `#45` → slug `pr-45`
- Branch `feature/auth-redesign` → slug `branch-feature-auth-redesign`
- Commit range `main..HEAD` → slug `range-main-head`
- File `src/app/api/payment/route.ts` → slug `file-route-ts` (basename без extension з prefix)
- Directory `src/features/payment/` → slug `dir-payment`
- Document `docs/plans/foo-bar-plan.md` → slug `doc-foo-bar-plan`

Path: `<output_dir>/YYYY-MM-DD-multi-review-<slug>.md`

Template:

```markdown
# Multi-Provider Review — <scope description>

**Date:** YYYY-MM-DD HH:MM
**Scope:** <scope type + identifier>
**Files reviewed:** <count> файлів (~<tokens>K input tokens)
**Reviewers:** Claude Opus 5 + Codex GPT-5.6 Sol + Gemini 3.1 Pro Preview + Cursor Composer 2.5 *(або 3, якщо lane дав ERROR)*

## Cost & Performance

| Lane | Tokens (in/out) | Time | Approx Cost |
|---|---|---|---|
| Claude Opus 5 | <in>K / <out>K | <m>m <s>s | (subscription) |
| Codex gpt-5.6-sol | <in>K / <out>K | <m>m <s>s | (ChatGPT Plus) |
| Gemini 3.1 Pro | <in>K / <out>K | <m>m <s>s | $<X.XX> |
| Composer 2.5 | n/a (CLI не віддає) | <m>m <s>s | (Cursor Pro — request-quota) |
| **Total** | <in>K / <out>K | <m>m <s>s wall | **~$<X.XX>** додатково (платний лише Gemini) |

> ⚠️ Gemini out = candidatesTokenCount + thoughtsTokenCount (thinking-токени). Якщо total > $3 — додати warning «expensive run, consider scoping smaller next time».

## Summary

<2-3 sentences: загальна картина. Скільки findings, скільки CRITICAL, чи є disagreements, top concern.>

## Consolidated Findings

### 🔴 CRITICAL (N)

#### #1: <title> [Voting: 4/4 ✅✅✅✅]
- **File:** `path:line`
- **Found by:** Claude, Codex, Gemini, Composer
- **Description:** <merged from reviewers>
- **Impact:** <merged>
- **Fix:** <merged, prefer most specific>

### 🟠 HIGH (N)
...

### 🟡 MEDIUM (N)
...

### 🟢 LOW (N)
...

### ℹ️ INFO (N)
...

## ⚠️ Disagreements (Highest-Value Section)

### Unique findings (1/4 voting)
> Ці findings знайшов лише один lane. Унікальний insight АБО шум — потрібна ручна оцінка (НЕ автоматично «high value»). Реальний самородок: CRITICAL #1 у один із бойових проєктів audit. Очікуваний промах: Composer зазвичай не бачить pubkey/key-refetch DoS — тож його «мовчання» про це ще не сигнал.

| Finding | Found by | Other reviewers said |
|---|---|---|
| <title> | Codex | Claude / Gemini / Composer: no mention |

### Severity disagreements
| Finding | Claude | Codex | Gemini | Composer | Resolved as |
|---|---|---|---|---|---|
| Tel link kiosk escape | not-found | MED | HIGH | MED | **HIGH** (max) |
| (приклад single-lane max) | not-found | not-found | not-found | CRIT | **→ verify** (лише 1 lane, +2 рівні — не у фінал тихо) |

### Conflicting recommendations
> Якщо A каже фіксити одним способом, B каже інакше → тут.

## Cross-Reference Matrix

| # | Finding | Severity | Claude | Codex | Gemini | Composer |
|---|---|---|:-:|:-:|:-:|:-:|
| 1 | <title> | CRIT | ✅ | ✅ | ✅ | ✅ |
| 2 | <title> | HIGH | ✅ | ❌ | ✅ | ✅ |
| 3 | <title> | MED | ❌ | ✅ | ❌ | ✅ |

## Batched Fix Plan

### Group A: Auth layer (3 issues)
- #1 CRITICAL
- #5 HIGH
- #12 LOW

### Group B: Input validation (2 issues)
...

## Raw Outputs (for forensic review)

🔴 **Перед `git add` — прогнати сканер секретів по кожному raw-файлу.** Трейс агента
містить усе, що той читав дорогою: локальні конфіги, `.env`, `settings.local.json`,
вивід `env`. Синтезований звіт чистий (його писав ти), а 200-кілобайтний додаток —
ні, і саме його ніхто не перечитує.

```bash
# у репо з власним гейтом
bash scripts/security-release-check.sh
# або мінімум, будь-де:
grep -nEI 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9_-]{30,}|ghp_[A-Za-z0-9]{30,}|re_[A-Za-z0-9_-]{25,}|[0-9]{8,}:[A-Za-z0-9_-]{30,}' <raw-файли>
```

Спрацювало — **не комітити**: raw лишається в `/tmp` на час сесії, у репо йде лише
синтез. Знайдений ключ вважати скомпрометованим і сказати юзеру про ротацію: видалення
файлу з індексу цього не скасовує, бо коміт уже в історії.

Ознака ризику — розмір: трейс Codex 200 КБ проти звіту 19 КБ. Усе зайве саме там.

Збережено у `<output_dir>/raw/`:
- `claude-<ts>.md` — Claude full response
- `codex-<ts>.txt` — Codex full response
- `gemini-<ts>.txt` — Gemini full response (+ `gemini-<ts>.raw.json` — сире REST-тіло з usageMetadata)
- `composer-<ts>.txt` — Composer full response (+ `composer-<ts>.raw` — сирий вивід cursor-agent до strip-ANSI)
```

### Phase 7: Summary to user

Коротке повідомлення у чаті (НЕ overwhelm):

```
✅ Multi-review завершено

📊 Знайдено: X CRITICAL, Y HIGH, Z MEDIUM, W LOW
⏱️ Wall time: M хв, ~$X.XX додатково (Gemini Pro)
📄 Звіт: <path-to-report>

🔝 Top 3 на що звернути увагу:
1. [SEVERITY] <title> — voting 4/4, у <file>
2. [SEVERITY] <title> — voting 1/4 (unique Codex — судити окремо: insight чи шум)
3. [SEVERITY] <title> — severity disagreement (Claude=HIGH, Composer=MED), розв'язано як HIGH

⚠️ Disagreements: <count> findings потребують manual judgment (всі у звіті, секція "Disagreements")

Наступний крок: відкрити <path> і прочитати Disagreements section ПЕРШОЮ — там найцінніше.
```

Якщо findings.count == 0 — використати "clean review" варіант з Phase 5 edge case.

---

## Cost expectations

Ціни звірені 2026-07-26 проти https://ai.google.dev/gemini-api/docs/pricing (Standard tier). Тільки Gemini-lane коштує грошей **за токени**; Claude + Codex + Composer входять у підписки. ⚠️ Composer = Cursor Pro: ліміт **по кількості запитів/місяць**, не по токенах — окремий бюджет, який великий або частий аудит може вичерпати (тоді lane дасть `COMPOSER_ERROR` quota → 3 з 4).

**Тарифи (за 1M токенів):**

| Модель | ≤200K вхід | >200K вхід | Примітка |
|---|---|---|---|
| **gemini-3.1-pro-preview** (основна) | $2.00 in / $12.00 out | $4.00 in / $18.00 out | >200K: вхід ×2, вихід ×1.5; якщо промпт перетинає 200K — ВСІ токени (вкл. вихід) білляться за long-context тарифом |
| **gemini-3.6-flash** (fallback на не-200) | $1.50 in / $7.50 out | (той самий — FLAT, без 200K-обриву) | cached input $0.15/1M; вихід дешевший за 3.5-flash |
| **gemini-3.5-flash** (secondary) | $1.50 in / $9.00 out | (FLAT) | лишається робочою |
| **gemini-2.5-pro** (secondary fallback) | $1.25 in / $10.00 out | $2.50 in / $15.00 out | дешевший Pro-tier |

⚠️ **gemini-3.1-pro-preview — це thinking-модель.** «Вихідні» токени для розрахунку = `candidatesTokenCount + thoughtsTokenCount` (reasoning-токени білляться як OUTPUT і часто у 2-6× більші за видимий текст). Не рахуй вихід лише по видимому тексту — недооціниш у рази. Формула з usageMetadata: input = `promptTokenCount`, output = `totalTokenCount − promptTokenCount`.

| Scope size | ~Вхідних токенів | Approx cost додатково* | Wall time |
|---|---|---|---|
| Single file (200 LOC) | ~5K | ~$0.05–0.10 | 2–5 хв |
| Small feature (5–10 files) | ~30K | ~$0.30–0.50 | 5–8 хв |
| Medium audit (20–30 files) | ~80K | ~$0.80–1.30 | 8–12 хв |
| Full project audit | ~150–200K | ~$1.80–3.00 | 12–20 хв |
| Above 200K | ⚠️ Pro tier дорожчає (вхід ×2, вихід ×1.5) — рекомендую розбити | $4–8+ | 15–30 хв |

\* Діапазон, бо thinking-токени плавають (для security-рев'ю reasoning зазвичай 1.5–6K токенів навіть на короткий промпт). Бери верхню межу для бюджету.

**Cost warning thresholds у звіті:**
- $1–3 — typical, без warning
- $3–5 — yellow warning «consider scoping smaller next time»
- $5+ — red warning «split scope для economy»

**Економія scope:** 200K — це ПРАЙСОВИЙ обрив (не ліміт контексту, бо у моделі 1M). Тримай Pro-промпт ≤200K щоб вхід лишався $2 (а не $4). Якщо аудит більший — або чанкуй, або переключи Gemini-lane на `gemini-3.6-flash` (flat $1.50/$7.50, без обриву).

---

## Failure modes / edge cases

1. **Один lane завис** → TaskStop з task_id + продовжити з решти, у звіт warning. ⚠️ **Цей watchdog стосувався СТАРОГО Gemini-CLI-підходу, який МІГ зависати** (real case 2026-05-31, salesai-analyzer: Gemini CLI при 6 паралельних чанках — 2 зависли назавжди БЕЗ completion-notification). **Тепер Gemini-lane = REST one-shot під `perl`-alarm 240с — зависнути так само НЕ може** (повертає одну HTTP-відповідь або таймаутиться). Машинерія нижче (mtime watchdog, `pkill -f gemini`) лишається лише як історична довідка / на випадок якщо хтось повернеться до CLI: детектуй по mtime out-файлу `stat -f "%z bytes, %Sm" -t "%H:%M:%S" out.txt`; >10-15 хв без змін = завис; дія `TaskStop` + `pkill -f gemini` (перечитай out ПЕРЕД тим як рахувати lane втраченим — race під час pkill).
2. **Codex rate-limited** (rare на ChatGPT Plus) → retry once з 30s backoff, далі warning
3. **Gemini 429 / 404 / 5xx** (Pro tier має квоти) → обгортка `tools/gemini-review.sh` АВТОМАТИЧНО ретраїть на `gemini-3.6-flash` (перевірено живим 2026-07-26: ListModels + `generateContent` 200). У звіт: `model=gemini-3.6-flash` + warning. Secondary за потреби: `gemini-2.5-pro` або `gemini-3-pro-preview` — обидва живі на 2026-07-26 (старе твердження «3-pro-preview мертвий, 404» більше не тримається; перевіряй перед тим як спиратись).
4. **Scope > context window** (~1M для Claude, ~200K для Codex/Gemini) → split на chunks по logical borders (e.g. per-feature subdirectory). Запустити N runs з тим самим PROMPT_BASE template (тільки контент різний). Об'єднати reports manually через додатковий synthesis step. Claude (1M ctx) стабільніший — бери ним весь scope одним прогоном, чанкуй лише Codex/Gemini. **Gemini-чанки тепер кожен = окремий незалежний REST-виклик обгортки** (старе застереження «партіями по 2-3 / watchdog на mtime» — obsolete, бо REST не тримає агента-процес). Синтез: екстрактор виловлює findings з кожного out (codex ховає звіт у кінці після ~12K рядків reasoning; gemini-заголовки формату `### [HIGH]` або `**[HIGH]`).
5. **Project не git і user не вказав output dir** → default `~/code-reviews/YYYY-MM-DD-multi-review-<slug>.md`
6. **Усі 3 lanes дали 0 findings** → clean review variant (див. Phase 5 edge case)
7. **Gemini lane = REST, не CLI (root cause фіксу 2026-05-31).** Headless `gemini -p` запускає агента з інструментами, який парсить `@`-токени з коду (Deno `std@0.177.0/...`, npm `@scope/pkg@ver`) як файлові шляхи, робить `stat()` і ламається (`Falling back to GrepTool` / `Error stating path` / `ENAMETOOLONG`) — особливо коли `@`-токенів багато; вивід стає відлунням коду без знахідок. Жоден CLI-прапор не лікує надійно (`-o json`, `--approval-mode plan`, `--policy deny`, `tools.core:[]` — усі емпірично спростовані: `@`-резолюція й `stat` відбуваються ВИЩЕ за tool-allowlist). REST не має ні агента, ні `@`-expansion, ні залежності від cwd. Тому Gemini-lane не може «зависнути» як CLI і не засмічує вивід.
8. **Gemini повернув порожньо / SAFETY-block / нерозбірливий JSON.** Обгортка safe-parse (`strict=False` + перевірки candidates/parts) НЕ падає — записує рядок `GEMINI_ERROR: ...` у out-файл (HTTP-код, finishReason, blockReason). Синтез детектує lane як втрачений якщо файл починається з `GEMINI_ERROR:` → продовжити з 3 з 4 (Phase 3 edge case), warning у звіт. `strict=False` обов'язковий: модель емітить сирі control-символи (переноси рядків) у текстовому полі, strict-парсер кидає `Invalid control character`.
9. **Composer lane недоступний / впав.** Обгортка `tools/composer-review.sh` пише `COMPOSER_ERROR: <причина>` у out-файл, синтез продовжує **на 3 з 4** (graceful degrade). Причини: не залогінений / нема Cursor Pro (`cursor-agent login`; API-ключ НЕ автентифікує CLI), `cursor-agent` не в PATH (він у `~/.local/bin` — обгортка перевіряє), timeout 900с, або безструктурний вивід. Під `perl`-alarm зависнути назавжди НЕ може. Найімовірніший degrade зі всіх 4 — бо Composer єдиний потребує окремої Cursor Pro підписки.
10. **Composer: руки геть від `--force`.** `--print` документовано має доступ до write/shell; read-only гарантія тримається на `--mode ask`, а НЕ на недокументованій парі `ask+force`. Для git-репо обгортка додає `--worktree` — будь-який випадковий запис іде у `~/.cursor/worktrees`, не у живе дерево. `--sandbox` НЕ вмикати: може зрізати мережевий виклик самої моделі до Cursor backend.

---

## Anti-patterns (не робити)

- ❌ **НЕ викликати Gemini-lane через CLI** (`gemini -p`) — headless CLI запускає агента, що ламається на `@`-токенах у коді. Тільки REST через `tools/gemini-review.sh`. (Root cause фейлів — Failure mode #7.)
- ❌ Polling background tasks через `sleep + cat` loops — використовувати harness notifications
- ❌ Запускати lanes послідовно «щоб простіше» — це 3x time. Завжди parallel.
- ❌ Фільтрувати findings нижче якоїсь confidence — у triangulation ВСЕ показувати, юзер вирішує
- ❌ Витирати raw outputs після synthesis — зберігати у `raw/` для воспроизводимості,
  але **тільки після сканера секретів** (див. Raw Outputs). Трейс агента містить усе,
  що він читав; у репо він іде чистим або не йде взагалі
- ❌ Комітити raw «щоб не загубився» до того, як подивився, що в ньому — саме так
  2026-08-26 ключ Gemini поїхав у git і був запушений
- ❌ Авто-фіксити знахідки — скіл тільки рев'юить + пропонує план, виправляє інша робота (`/ce-work`, `/autoresearch:fix`)
- ❌ Викликати скіл для звичайних code-review задач — це 5% use case, не дефолт
- ❌ Передавати довгі промпти інлайн через `exec "<long-string>"` — пиши спочатку у /tmp файл, потім `"$(cat /tmp/file)"`. (Стосується Codex/Claude lane-ів; для Gemini промпт іде у JSON-поле через `python json.dumps`, не у shell-аргумент.)
- ❌ **Composer-lane: НЕ давати `--force`/`--yolo`** на чужий код — read-only тримається на `--mode ask`; і не вмикати `--sandbox` (зріже мережевий виклик моделі). Деталі — Failure mode #10.
- ❌ **Composer-lane: на еталон-тестах НЕ давати workspace із готовими звітами** (`findings.md`, `*-validation.md` у репо) — Composer їх прочитає й «спише» (виміряно 2026-06-02: брудний прогін 5/5 «важких unique» vs чистий 4/5). Для бенчмарку — ізольована копія коду без звітів. (Стосується лише тестування скіла; у проді workspace=репо нормально.)

---

## Tools (3-й шар скіла)

- **`tools/gemini-review.sh`** — детермінований виклик Gemini-lane через REST `generateContent` (обходить зламаний CLI-агент). Args: `<prompt-file> <out-file> [model]`. Будує JSON-тіло (`python json.dumps`), кличе REST під `perl`-alarm 240с, auto-fallback `gemini-3.1-pro-preview` → `gemini-3.6-flash` на не-200, safe-parse (`strict=False`), пише рев'ю у out-файл + рядок токенів `in=.. out=.. think=.. total=..` у stderr. Verified 2026-05-31 на коді з `@`-токенами: чистий рев'ю, 0 GrepTool/stat-noise, коректний usageMetadata.
- **`tools/composer-review.sh`** — детермінований виклик Composer-lane через `cursor-agent` headless. Args: `<prompt-file> <out-file> <workspace-dir> [model]`. Перевіряє PATH і логін (`cursor-agent status`); для git-репо ізолює через `--worktree`; запускає `--print --mode ask --trust` (read-only, БЕЗ `--force`) під `perl`-alarm 900с; strip-ANSI; success визначає за наявністю структури рев'ю (severity-мітки / Top concern / заголовки), інакше — `COMPOSER_ERROR:` (не залогінений / нема Pro / timeout / порожньо) → синтез на 3 з 4. Токенів CLI не віддає (usage = «Cursor Pro request-quota»). Verified 2026-06-02 на один із бойових проєктів: rc=0, ~16KB, 19 findings, стабільно без зависань.

---

## Related skills

- `/ce-review` — 17 персон на Sonnet, дефолт для звичайного code-review (95% задач)
- `/autoresearch:security` — security-focused single-provider deep audit
- `/ce-plan` — для планування FIX-ів на основі multi-review findings
- `/save-lesson` — після multi-review записати у Wiki якщо знайдено non-obvious patterns

---

## Origin

Деталі прогонів — у Wiki, тут лише те, що змінює поведінку:

- власні записи про крос-провайдерну перевірку · `...2026-05-21-cross-provider-security-audit-validation.md` — матриця findings, за якою міряються lane-и.
- **Gemini-lane = REST** (2026-05-31): CLI-агент ламався на `@`-токенах у коді → `tools/gemini-review.sh`.
- **Composer-lane доданий** (2026-06-02): бере 4/5 «важких unique» на ізольованому коді; стабільна сліпа пляма — pubkey/key-refetch DoS. Для еталон-тестів workspace без готових звітів, інакше він їх спише.
- **Перший бойовий 4-lane** (2026-06-03, PR #157): триангуляція спіймала впевнену помилку Claude на `COMMIT\n;` — звідси правило live-verify фактичних розбіжностей у Phase 5.
