#!/usr/bin/env node
// Draws the cookbook's cover, art/cover.png: 1080 x 1440 (the Kobo Aura HD's screen, upright).
// It is the Kobo's sleep screen, so: white paper and thick black ink. The doodles sit in a ring
// round the title, inside a recipe card.
//
//   node tools/make-cover.mjs                        the words from book.json
//   node tools/make-cover.mjs --title "Nana's Kitchen" --tagline "the family recipes"
//
// The words, top to bottom (each can also be given here, which wins over book.json):
//   --top       a small line over the ring    book.json cover.top      ("recipes from")
//   --title     the big words in the ring     book.json title
//   --tagline   a line under the ring         book.json cover.tagline  ("family recipes")
//   --bottom    the last line                 book.json cover.bottom   ("made with love {heart}")
// "{heart}" is the little heart. A line set to "" in book.json is left out.
//
// It is laid out as a little HTML page and photographed with headless Google Chrome (see
// tools/make-art.mjs), with the doodles in art/ and the handwriting fonts in fonts/.
// Run it again whenever the title changes, then put the recipes on the Kobo again.
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { options } from './args.mjs';
import { loadKitchenBook, KitchenError } from './kitchen-book.mjs';
import { ART, draw, esc, page } from './make-art.mjs';

const USAGE = 'Usage: node tools/make-cover.mjs [--title WORDS] [--top WORDS] [--tagline WORDS] [--bottom WORDS]';
const opts = options({ title: { type: 'string' }, top: { type: 'string' }, tagline: { type: 'string' }, bottom: { type: 'string' } }, USAGE);

let settings;
try {
  ({ settings } = loadKitchenBook());
} catch (e) {
  if (!(e instanceof KitchenError)) throw e;
  console.error(e.message);
  process.exit(1);
}
const pick = (flag, fromBook, dflt) => (opts[flag] !== undefined ? opts[flag] : fromBook !== undefined ? fromBook : dflt);
const title = pick('title', settings.title, 'Recipe Box');
const top = pick('top', settings.cover.top, 'recipes from');
const tagline = pick('tagline', settings.cover.tagline, 'family recipes');
const bottom = pick('bottom', settings.cover.bottom, 'made with love {heart}');

const W = 1080, H = 1440;
// Doodles go in as data: URIs so the page has no file paths to get wrong.
const art = (name) => `data:image/png;base64,${readFileSync(join(ART, name + '.png')).toString('base64')}`;
const withHeart = (s) => esc(s).replace(/\{heart\}/g, `<img class="h" src="${art('heart')}" alt="">`);

// Split the title over two lines (at the space nearest the middle) and size it to fit inside the ring.
function titleLines(t) {
  const words = t.trim().split(/\s+/);
  if (words.length < 2) return [t.trim()];
  let best = 1, bestDiff = Infinity;
  for (let i = 1; i < words.length; i++) {
    const diff = Math.abs(words.slice(0, i).join(' ').length - words.slice(i).join(' ').length);
    if (diff < bestDiff) { best = i; bestDiff = diff; }
  }
  return [words.slice(0, best).join(' '), words.slice(best).join(' ')];
}
const lines = titleLines(title);
const longest = Math.max(...lines.map((l) => l.length));
const titleSize = Math.round(Math.min(168, 600 / (longest * 0.47))); // Gochi Hand is ~0.47em per letter

// The ring: doodles evenly round a circle, the title in the middle.
const RING = ['pot', 'flame', 'bowl', 'bread', 'cake', 'cookie', 'whisk', 'heart'];
const CX = W / 2, CY = 690, R = 372, D = 118; // centre, radius, doodle size
const ring = RING.map((name, i) => {
  const a = (i / RING.length) * 2 * Math.PI - Math.PI / 2; // start at the top
  const x = Math.round(CX + R * Math.cos(a) - D / 2), y = Math.round(CY + R * Math.sin(a) - D / 2);
  const tilt = (i % 2 ? 8 : -8); // a little wobble so it looks hand-placed
  return `<img class="d" src="${art(name)}" style="left:${x}px;top:${y}px;transform:rotate(${tilt}deg)" alt="">`;
}).join('\n');
// small dots between the doodles, like a dotted circle
const dots = Array.from({ length: RING.length }, (_, i) => {
  const a = ((i + 0.5) / RING.length) * 2 * Math.PI - Math.PI / 2;
  return `<b class="dot" style="left:${Math.round(CX + R * Math.cos(a) - 7)}px;top:${Math.round(CY + R * Math.sin(a) - 7)}px"></b>`;
}).join('');

const html = page(W, H, `
<div class="card"></div><div class="inner"></div>
${top ? `<p class="from"><i></i>${esc(top)}<i></i></p>` : ''}
${ring}
${dots}
<div class="title">${lines.map(esc).join('<br>')}<img class="wave" src="${art('wave')}" alt=""></div>
${tagline ? `<p class="tagline">${esc(tagline)}</p>` : ''}
${bottom ? `<p class="love">${withHeart(bottom)}</p>` : ''}
`, `
body{display:block;position:relative;font-family:"Patrick Hand",Georgia,serif}
p{margin:0}
/* the recipe card: thick dashed edge, round corners, a solid line just inside */
.card{position:absolute;left:44px;top:44px;right:44px;bottom:44px;border:7px dashed #000;border-radius:46px}
.inner{position:absolute;left:70px;top:70px;right:70px;bottom:70px;border:3px solid #000;border-radius:30px}
.from{position:absolute;left:0;right:0;top:158px;text-align:center;font-size:44px;letter-spacing:3px}
.from i{font-style:normal;display:inline-block;width:110px;border-top:4px solid #000;vertical-align:middle;margin:0 22px}
img.d{position:absolute;width:${D}px;height:${D}px}
.dot{position:absolute;width:14px;height:14px;border-radius:7px;background:#000}
.title{position:absolute;left:0;right:0;top:${CY}px;transform:translateY(-58%);text-align:center;
  font-family:"Gochi Hand","Patrick Hand",Georgia,serif;font-size:${titleSize}px;line-height:.98}
.wave{position:relative;display:block;margin:22px auto 0;width:300px;height:18px}
.tagline{position:absolute;left:90px;right:90px;top:1168px;text-align:center;font-size:54px;line-height:1.15}
.love{position:absolute;left:0;right:0;top:1268px;text-align:center;font-family:"Gochi Hand","Patrick Hand",Georgia,serif;font-size:50px}
.love .h{position:relative;width:44px;height:44px;vertical-align:middle;top:-4px;margin:0 6px}
`);

try {
  const [out] = await draw({ cover: { w: W, h: H, html } });
  const d = readFileSync(out);
  const [w, h] = [d.readUInt32BE(16), d.readUInt32BE(20)];
  console.log(`Wrote art/cover.png (${w} x ${h}, ${Math.round(statSync(out).size / 1024)} KB): "${top}" / "${title}" / "${tagline}" / "${bottom}"`);
  if (w !== W || h !== H) { console.error(`Expected ${W} x ${H}!`); process.exit(1); }
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
