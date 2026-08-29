#!/usr/bin/env python3
"""Витягує ОСТАННІЙ валідний JSON-обʼєкт із шумного виводу CLI (codex/gemini).

Використання: python3 extract-last-json.py <файл-виводу> [ключ] [--anchor duplicates]
Друкує JSON; з ключем — лише це поле. Самоперевірка: --selftest.
"""
import json, re, sys

# ponytail: наївний баланс дужок — зламається, якщо у JSON-рядках будуть { };
# якщо таке трапиться — перейти на потоковий json.JSONDecoder().raw_decode.
def last_json(raw, anchor='duplicates'):
    pat = re.compile(r'\{\s*"' + re.escape(anchor) + '"')
    for m in reversed(list(pat.finditer(raw))):
        depth = 0
        for i, ch in enumerate(raw[m.start():]):
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(raw[m.start():m.start() + i + 1])
                    except json.JSONDecodeError:
                        break
    return None

def selftest():
    noisy = 'лог\n{"duplicates":[]}\nще лог\n{"duplicates":[{"lines":"1-2","reason":"тест"}],"outdated":[]}\nхвіст'
    d = last_json(noisy)
    assert d and d['duplicates'][0]['lines'] == '1-2', d
    print('SELFTEST PASS')

if __name__ == '__main__':
    if '--selftest' in sys.argv:
        selftest(); sys.exit(0)
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    anchor = sys.argv[sys.argv.index('--anchor') + 1] if '--anchor' in sys.argv else 'duplicates'
    d = last_json(open(args[0]).read(), anchor)
    if d is None:
        sys.exit('JSON не знайдено')
    if len(args) > 1:
        d = d.get(args[1], [])
    print(json.dumps(d, ensure_ascii=False, indent=1))
