// Скільки слів на готових сторінках сайту.
// Порожня сторінка не ранжується: пошук не має що читати, а чат-боти — що цитувати.
//
// Рахуємо на зібраному HTML (.next/server/app/**), тобто рівно те, що бачить робот,
// а не те, що ми думаємо, ніби написали.
//
// Запуск: npm run build && node scripts/page-words.mjs
//         node scripts/page-words.mjs poslugy      (тільки один розділ)

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = '.next/server/app';
const filter = process.argv[2] || '';

if (!existsSync(ROOT)) {
  console.error(`Немає ${ROOT}. Спершу: npm run build`);
  process.exit(1);
}

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (name.endsWith('.html')) out.push(p);
  }
  return out;
}

function words(html) {
  const text = html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&[a-z]+;|&#\d+;/gi, ' ');
  return text.split(/\s+/).filter((w) => /[a-zа-яіїєґ0-9]/i.test(w)).length;
}

const pages = walk(ROOT)
  .map((p) => ({ url: '/' + p.slice(ROOT.length + 1).replace(/\.html$/, ''), n: words(readFileSync(p, 'utf8')) }))
  .filter((p) => !filter || p.url.includes(filter))
  .sort((a, b) => a.n - b.n);

console.log(`\nСлів на сторінці (від найкоротшої)\n`);
for (const p of pages) {
  const mark = p.n < 300 ? ' ← тонка' : p.n < 500 ? ' ←' : '';
  console.log(`  ${String(p.n).padStart(5)}  ${p.url}${mark}`);
}
console.log(`\nСторінок: ${pages.length}   Медіана: ${pages[Math.floor(pages.length / 2)]?.n}`);
