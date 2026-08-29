// Скільки сторінки міст схожі одна на одну.
// Google вважає майже однакові сторінки «дверними» (doorway) і знецінює весь домен,
// тому це не косметика, а запобіжник.
//
// Міряємо на СПРАВЖНЬОМУ тексті готових сторінок (.next/server/app/remont/*.html),
// а не на вихідних даних — бо в HTML потрапляє й спільна обгортка (меню, футер,
// блоки послуг), і саме її бачить пошуковий робот.
//
// Дві метрики:
//   shingle — збіг трислівних послідовностей (так near-duplicate шукає пошук).
//             Це головний показник. Ціль: < 60 %.
//   cosine  — збіг словника (частоти окремих слів). Довідково: у текстів однієї
//             тематики він високий завжди, бо слова «ремонт», «майстер», «техніка»
//             є всюди.
//
// Запуск: npm run build && node scripts/city-similarity.mjs
//         node scripts/city-similarity.mjs --unique   (тільки унікальний текст міста,
//                                                      без спільної обгортки сайту)

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const DIR = '.next/server/app/remont';
const LIMIT = 60; // поріг у відсотках
const uniqueOnly = process.argv.includes('--unique');

if (!existsSync(DIR)) {
  console.error(`Немає ${DIR}. Спершу: npm run build`);
  process.exit(1);
}

// HTML → чистий текст.
function htmlToText(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&[a-z]+;|&#\d+;/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// Унікальна частина сторінки — від хлібних крихт до блоку послуг.
// Далі йде спільна для всіх міст обгортка (послуги, процес, футер).
function uniquePart(text) {
  const start = text.indexOf('Головна');
  const end = text.indexOf('Не поспішайте купувати нову');
  if (start === -1 || end === -1 || end <= start) return text;
  return text.slice(start, end);
}

function words(text) {
  return text
    .toLowerCase()
    .replace(/[^a-zа-яіїєґ'0-9\s]/gi, ' ')
    .split(/\s+/)
    .filter((w) => w.length > 2);
}

function shingles(ws, n = 3) {
  const set = new Set();
  for (let i = 0; i + n <= ws.length; i++) set.add(ws.slice(i, i + n).join(' '));
  return set;
}

function jaccard(a, b) {
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  const union = a.size + b.size - inter;
  return union === 0 ? 0 : (inter / union) * 100;
}

function cosine(aw, bw) {
  const fa = new Map();
  const fb = new Map();
  for (const w of aw) fa.set(w, (fa.get(w) || 0) + 1);
  for (const w of bw) fb.set(w, (fb.get(w) || 0) + 1);
  let dot = 0;
  for (const [w, c] of fa) if (fb.has(w)) dot += c * fb.get(w);
  const na = Math.sqrt([...fa.values()].reduce((s, c) => s + c * c, 0));
  const nb = Math.sqrt([...fb.values()].reduce((s, c) => s + c * c, 0));
  return na && nb ? (dot / (na * nb)) * 100 : 0;
}

// Міста, яким уже написано власний текст (ключі верхнього рівня в city-content.ts).
// Поки робота триває, порівнювати ненаписані між собою немає сенсу — вони однакові
// за визначенням. Прапорець --all вмикає перевірку геть усіх сторінок.
function citiesWithContent() {
  const src = readFileSync('src/lib/city-content.ts', 'utf8');
  const body = src.slice(src.indexOf('CITY_CONTENT: Record<string, CityContent> = {'));
  return new Set([...body.matchAll(/^ {2}'?([a-z-]+)'?: \{$/gm)].map((m) => m[1]));
}

const all = process.argv.includes('--all');
const written = citiesWithContent();

// khmelnytskyi не рахуємо: ця адреса перенаправляється (301) на головну,
// сторінки в пошуку не існує — див. next.config.ts.
const files = readdirSync(DIR)
  .filter((f) => f.endsWith('.html') && f !== 'khmelnytskyi.html')
  .filter((f) => all || written.has(f.replace(/\.html$/, '')));

if (!files.length) {
  console.error('Жодного міста з написаним текстом. Спершу заповніть city-content.ts.');
  process.exit(1);
}
const pages = files.map((f) => {
  const raw = htmlToText(readFileSync(join(DIR, f), 'utf8'));
  const text = uniqueOnly ? uniquePart(raw) : raw;
  const ws = words(text);
  return { slug: f.replace(/\.html$/, ''), ws, sh: shingles(ws), len: ws.length };
});

const pairs = [];
for (let i = 0; i < pages.length; i++) {
  for (let j = i + 1; j < pages.length; j++) {
    pairs.push({
      a: pages[i].slug,
      b: pages[j].slug,
      shingle: jaccard(pages[i].sh, pages[j].sh),
      cosine: cosine(pages[i].ws, pages[j].ws),
    });
  }
}
pairs.sort((x, y) => y.shingle - x.shingle);

const over = pairs.filter((p) => p.shingle > LIMIT);
const mode = uniqueOnly ? 'ТІЛЬКИ УНІКАЛЬНИЙ ТЕКСТ МІСТА' : 'ПОВНА СТОРІНКА (як бачить робот)';

console.log(`\nСхожість сторінок міст — ${mode}`);
console.log(`Сторінок: ${pages.length}   Пар: ${pairs.length}   Поріг: ${LIMIT}%`);
console.log(all ? 'Рахуємо ВСІ сторінки міст.' : `Рахуємо тільки міста з написаним текстом (${written.size} із 36).\n`);

const shortest = [...pages].sort((a, b) => a.len - b.len).slice(0, 3);
console.log('Найкоротші сторінки (слів):', shortest.map((p) => `${p.slug} ${p.len}`).join(', '));

console.log('\nНАЙСХОЖІШІ 10 ПАР (shingle / cosine):');
for (const p of pairs.slice(0, 10)) {
  const flag = p.shingle > LIMIT ? '  ⚠️' : '';
  console.log(`  ${p.shingle.toFixed(1)}% / ${p.cosine.toFixed(1)}%   ${p.a} ↔ ${p.b}${flag}`);
}

const avg = pairs.reduce((s, p) => s + p.shingle, 0) / pairs.length;
console.log(`\nМаксимум: ${pairs[0].shingle.toFixed(1)}%   Середнє: ${avg.toFixed(1)}%`);

if (over.length) {
  console.log(`\n❌ ПРОВАЛ: ${over.length} пар вище ${LIMIT}%. Переписати ці міста.`);
  process.exit(1);
}
console.log(`\n✅ Усі пари нижче ${LIMIT}%.`);
