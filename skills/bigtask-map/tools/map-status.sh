#!/usr/bin/env bash
# Стан карти без читання всього файлу: скільки закрито, що можна брати зараз.
# Використання: bash map-status.sh docs/maps/<назва>.md
set -euo pipefail

MAP="${1:-}"
[ -z "$MAP" ] && { echo "Використання: bash map-status.sh <шлях-до-карти.md>"; exit 2; }
[ -f "$MAP" ] || { echo "Нема файлу: $MAP"; exit 1; }

done_n=$(grep -c '^### \[x\]' "$MAP" || true)
wip_n=$(grep -c '^### \[~\]' "$MAP" || true)
open_n=$(grep -c '^### \[ \]' "$MAP" || true)

echo "── $(basename "$MAP")"
sed -n '/^## Пункт призначення/,/^## /p' "$MAP" | sed '1d;/^## /d;/^$/d' | head -3
echo
echo "Закрито: $done_n · В роботі: $wip_n · Відкрито: $open_n"

# Рубіж: відкриті пункти, які нікого не чекають або чекають вже закритого.
echo
echo "── Можна брати зараз:"
closed_titles=$(grep '^### \[x\]' "$MAP" | sed 's/^### \[x\] //' || true)
found=0
while IFS= read -r line; do
  title="${line#'### [ ] '}"
  waits=$(awk -v t="$line" '$0==t{f=1} f&&/^\*\*Чекає:\*\*/{sub(/^\*\*Чекає:\*\* /,""); print; exit}' "$MAP")
  if [ -z "$waits" ] || [ "$waits" = "—" ] || grep -qxF "$waits" <<<"$closed_titles"; then
    echo "  • $title"
    found=1
  fi
done < <(grep '^### \[ \]' "$MAP" || true)
[ "$found" -eq 0 ] && echo "  (нічого — усе або закрито, або заблоковано)"

fog=$(sed -n '/^## Ще не сформульовано/,/^## Поза межами/p' "$MAP" | grep -c '^- ' || true)
echo
echo "У тумані: $fog"
