#!/usr/bin/env node
// Draws the kitchen's pictures into art/ (black ink, so they stay crisp on e-ink):
//
//   the chapter doodles  pot, flame, bowl, bread, cake, cookie, whisk, samosa (192 x 192,
//                        see-through)
//   heart, wave          the little heart ({heart} in the footer) and the wavy line under titles
//   tile-az, tile-how    the A to Z and How it works tiles (240 x 240)
//
//   node tools/make-art.mjs        (re)draw them all
//
// The doodles are small SVG drawings, turned into PNG by macOS's own sips. The tiles have
// handwriting in them, so they are tiny HTML pages photographed by headless Google Chrome (as
// tools/make-cover.mjs does for the cover), then stored as greyscale. The fonts come from fonts/.
// To add a doodle of your own, add it to DOODLES below (an SVG on a 48 x 48 grid) and run this
// again; or put any black-on-transparent PNG in art/ yourself. Then give it to a chapter in
// book.json's "doodles".
// Other tools import draw() to make pictures of their own.
import { writeFileSync, existsSync, mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const run = promisify(execFile);
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const HERE = fileURLToPath(new URL('.', import.meta.url));
export const FONTS = join(HERE, '..', 'fonts');
export const ART = join(HERE, '..', 'art');
export const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/* ---------- the doodles: thick black lines, drawn at 4 times their grid size ---------- */
const doodle = (inner, box = '0 0 48 48') =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${box.split(' ')[2] * 4}" height="${box.split(' ')[3] * 4}" viewBox="${box}" fill="none" stroke="#000" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
const wave = (n) => 'M3 7' + Array.from({ length: n }, () => 'q6 -8 12 0t12 0').join('');
export const DOODLES = {
  pot: doodle('<path d="M10 23h28v11a6 6 0 0 1-6 6H16a6 6 0 0 1-6-6z"/><path d="M5 26h5M38 26h5M8 23h32"/><path d="M18 17c-3-3 3-5 0-9M27 17c-3-3 3-5 0-9"/>'),
  flame: doodle('<path d="M24 5c2 9 11 11 11 21a11 11 0 0 1-22 0c0-5 3-8 4-12 2 2 3 4 3 7 3-4 4-9 4-16z"/><path d="M24 40a5 5 0 0 1-5-5c0-3 3-4 5-8 2 4 5 5 5 8a5 5 0 0 1-5 5z"/>'),
  bowl: doodle('<path d="M5 24h38a19 17 0 0 1-38 0z"/><path d="M15 24c0-6 4-6 4-13M23 24c0-6 4-6 4-13M31 6l10 15"/>'),
  bread: doodle('<path d="M8 22a8 8 0 0 1 8-10h16a8 8 0 0 1 8 10v14a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2z"/><path d="M17 20l3 5M25 20l3 5"/>'),
  cake: doodle('<path d="M6 41h36M10 41V27h28v14"/><path d="M10 33c4 3 6-3 9 0s6-3 9 0 6-3 10 0"/><path d="M16 27v-6h16v6M24 21v-6"/><path d="M24 15c-3-2-1-5 0-8 1 3 3 6 0 8z" fill="#000"/>'),
  cookie: doodle('<circle cx="24" cy="24" r="17"/><path stroke-width="5" d="M17 18h.01M28 15h.01M31 27h.01M19 30h.01M24 23h.01M26 34h.01"/>'),
  whisk: doodle('<path d="M24 27v16"/><path d="M24 27c-11-4-11-19 0-22 11 3 11 18 0 22z"/><path d="M24 27c-4-7-4-15 0-22 4 7 4 15 0 22z"/>'),
  // a samosa: a plump folded triangle, its edge crimped
  samosa: doodle('<path d="M24 6C26.5 6 27.5 7.5 29 10Q37 21 41.5 33C43 37 41 40 37 40H11C7 40 5 37 6.5 33Q11 21 19 10C20.5 7.5 21.5 6 24 6z"/><path d="M24 7.5Q25 24 32 39.5"/><path d="M10.5 30l2.5 1.5M8.5 34.5l3 1M13 25.5l2.5 2"/>'),
  heart: doodle('<path fill="#000" d="M24 41C9 30 5 22 9 15c3-5 11-5 15 1 4-6 12-6 15-1 4 7 0 15-15 26z"/>'),
  wave: doodle(`<path d="${wave(8)}"/>`, '0 0 198 12'),
};

// SVG -> PNG with macOS's sips (it keeps the see-through background).
export async function drawDoodles(doodles = DOODLES, dir = ART) {
  mkdirSync(dir, { recursive: true });
  const tmp = mkdtempSync(join(tmpdir(), 'kitchen-doodles-'));
  try {
    for (const [name, svg] of Object.entries(doodles)) {
      const src = join(tmp, `${name}.svg`);
      writeFileSync(src, svg);
      await run('sips', ['-s', 'format', 'png', src, '--out', resolve(dir, `${name}.png`)]);
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  return Object.keys(doodles).map((n) => join(dir, `${n}.png`));
}

/* ---------- pictures with words: HTML pages, photographed by headless Chrome ---------- */

// The page every picture is drawn on: white paper, black ink, the two handwriting fonts.
export const page = (w, h, body, css = '') => `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
@font-face{font-family:"Gochi Hand";src:url("${pathToFileURL(join(FONTS, 'GochiHand-Regular.ttf')).href}");font-display:block}
@font-face{font-family:"Patrick Hand";src:url("${pathToFileURL(join(FONTS, 'PatrickHand-Regular.ttf')).href}");font-display:block}
html,body{margin:0;width:${w}px;height:${h}px;overflow:hidden;background:#fff;color:#000}
body{display:flex;align-items:center;justify-content:center;font-family:"Gochi Hand","Patrick Hand",serif}
${css}</style></head><body>${body}</body></html>`;

// A word or two in a hand-drawn circle: the A to Z and How it works tiles.
export function badge(n, { d = 96 } = {}) {
  return {
    w: d, h: d,
    html: page(d, d, `<div class="c">${esc(n)}</div>`, `
.c{box-sizing:border-box;width:${d - 6}px;height:${d - 6}px;border:5px solid #000;border-radius:50%;display:flex;align-items:center;
  justify-content:center;font-size:${Math.round(d * ([0.6, 0.6, 0.52][String(n).length] || 0.36))}px;line-height:1;padding-top:${Math.round(d * 0.04)}px}`),
  };
}

// Draws { name: { w, h, html } } to <dir>/<name>.png, a few at a time, stored as greyscale.
export async function draw(pictures, dir = ART) {
  if (!existsSync(CHROME)) throw new Error(`Google Chrome isn't at ${CHROME}. It is needed to draw pictures with words in them (set CHROME=<path> if it's elsewhere).`);
  mkdirSync(dir, { recursive: true });
  const tmp = mkdtempSync(join(tmpdir(), 'kitchen-art-'));
  const names = Object.keys(pictures);
  try {
    let next = 0;
    const worker = async () => {
      while (next < names.length) {
        const name = names[next++];
        const { w, h, html } = pictures[name];
        const src = join(tmp, `${name}.html`);
        const out = resolve(dir, `${name}.png`);
        writeFileSync(src, html);
        // A throwaway profile, and --use-mock-keychain / --password-store=basic so it never
        // reaches for the Mac's keychain (otherwise macOS pops up "Keychain Not Found" for every
        // picture: click Cancel on those, never "Reset To Defaults").
        await run(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
          '--use-mock-keychain', '--password-store=basic', '--no-first-run', '--no-default-browser-check',
          `--window-size=${w},${h}`, '--virtual-time-budget=3000', `--user-data-dir=${join(tmp, `profile-${name}`)}`,
          `--screenshot=${out}`, pathToFileURL(src).href], { timeout: 60000 });
        if (!existsSync(out)) throw new Error(`Chrome didn't draw ${name}.png`);
        // E-ink shows greys only: store it as greyscale (smaller, nothing for the Kobo to convert).
        await run('sips', ['-m', '/System/Library/ColorSync/Profiles/Generic Gray Profile.icc', out, '--out', out]).catch(() => {});
      }
    };
    await Promise.all(Array.from({ length: Math.min(4, names.length) }, worker));
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  return names.map((n) => join(dir, `${n}.png`));
}

// The two tiles on the Recipe box besides the chapters.
export const TILES = {
  'tile-az': badge('A–Z', { d: 240 }),
  'tile-how': badge('?', { d: 240 }),
};

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const t = Date.now();
  const files = [...await drawDoodles(), ...await draw(TILES)];
  console.log(`Drew ${files.length} pictures into art/ in ${((Date.now() - t) / 1000).toFixed(1)} s. (The cover is tools/make-cover.mjs.)`);
}
