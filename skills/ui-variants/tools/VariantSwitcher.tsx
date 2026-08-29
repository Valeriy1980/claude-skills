/**
 * Плаваюча панель перемикання варіантів прототипу.
 *
 * Працює будь-де (Next.js App Router, Vite + React Router, CRA) — читає адресний
 * рядок напряму, без роутера. Сама ховається у продакшн-збірці.
 *
 * Використання:
 *   const VARIANTS = { A: 'Класика', B: 'Бічне меню', C: 'Крупний екран' };
 *   const variant = useVariant(VARIANTS);
 *   ...
 *   <VariantSwitcher variants={VARIANTS} />
 */
'use client';

import { useCallback, useEffect, useState } from 'react';

type Variants = Record<string, string>;

/** Поточний варіант з адреси. Повертає перший ключ, якщо параметра нема або він чужий. */
export function useVariant(variants: Variants, param = 'variant') {
  const keys = Object.keys(variants);
  const fallback = keys[0];
  const [current, setCurrent] = useState(fallback);

  useEffect(() => {
    const read = () => {
      const v = new URLSearchParams(window.location.search).get(param);
      setCurrent(v && keys.includes(v) ? v : fallback);
    };
    read();
    window.addEventListener('popstate', read);
    return () => window.removeEventListener('popstate', read);
  }, [param, keys.join(','), fallback]);

  return current;
}

export function VariantSwitcher({ variants, param = 'variant' }: { variants: Variants; param?: string }) {
  const keys = Object.keys(variants);
  const current = useVariant(variants, param);
  const idx = Math.max(0, keys.indexOf(current));

  const go = useCallback((delta: number) => {
    const next = keys[(idx + delta + keys.length) % keys.length];
    const url = new URL(window.location.href);
    url.searchParams.set(param, next);
    window.history.replaceState({}, '', url);
    window.dispatchEvent(new PopStateEvent('popstate'));
  }, [idx, keys.join(','), param]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // не перехоплювати стрілки, коли користувач друкує
      const el = document.activeElement as HTMLElement | null;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
      if (e.key === 'ArrowLeft') go(-1);
      if (e.key === 'ArrowRight') go(1);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [go]);

  // ponytail: у проді панелі не існує — випадковий мердж прототипу не покаже її людям
  if (process.env.NODE_ENV === 'production') return null;

  const btn: React.CSSProperties = {
    background: 'none', border: 'none', color: '#fff',
    fontSize: 18, lineHeight: 1, cursor: 'pointer', padding: '0 10px',
  };

  return (
    <div
      style={{
        position: 'fixed', bottom: 20, left: '50%', transform: 'translateX(-50%)',
        display: 'flex', alignItems: 'center', gap: 4, zIndex: 9999,
        background: '#111', color: '#fff', borderRadius: 999,
        padding: '10px 8px', boxShadow: '0 8px 24px rgba(0,0,0,.35)',
        font: '500 14px/1 system-ui, sans-serif', userSelect: 'none',
      }}
    >
      <button style={btn} onClick={() => go(-1)} aria-label="Попередній варіант">←</button>
      <span style={{ minWidth: 160, textAlign: 'center' }}>
        {current} — {variants[current]}
      </span>
      <button style={btn} onClick={() => go(1)} aria-label="Наступний варіант">→</button>
    </div>
  );
}
