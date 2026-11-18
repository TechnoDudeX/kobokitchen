#!/usr/bin/env node
// The recipes as data for the Kobo kitchen app (kobo-app/kitchen.koplugin, a KOReader plugin):
//
//   recipes.json  the chapters, the A to Z order and every recipe (from recipes.js + book.json)
//   art/*.png     the chapter doodles, the heart, the wave, the A to Z and How tiles, the cover
//   latest.json   the edition's date, when it was built, how many recipes, and every file with
//                 its size and SHA-256, so the app can tell what's new and check what it gets
//
// The app gets these by cable (tools/kobo-install.mjs) or, only if you set that up, over Wi-Fi
// from a website of yours (tools/kitchen-publish.mjs). The same recipes and settings always give
// the same files; only latest.json says when they were built.
//
//   node tools/kitchen-bundle.mjs --out <folder>   write it there (an empty folder, or one that
//                                                  holds an older bundle, which is replaced)
//
//   buildBundle({ edition, built, kit }) -> { files: [{ path, data }], latest, count }
//
// recipes.json (format 1):
//   { format, title, tagline, footer, bundleUrl, settings: { font, textSize, cooking },
//     chapters: [{ id, name, short, doodle, recipes: [slug, ...] }],      in the book's order
//     az: [slug, ...],                                                     every recipe by name
//     recipes: { slug: { title, chapter (id), aka, notes: [...], gap,
//                        sections: [{ heading, ingredients: [{ amount, text }], steps: [...] }] } } }
// Text is plain: "(?)" marks a word that was hard to read. "{heart}" in the footer is a heart,
// "{count}" in the tagline the number of recipes. bundleUrl is "" when Wi-Fi updates are off.
// latest.json: { format, edition: "YYYY-MM-DD", built: "YYYY-MM-DDTHH:MM:SSZ", recipes,
//                files: [{ path, bytes, sha256 }] }
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, readdirSync, unlinkSync, statSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { options } from './args.mjs';
import { loadKitchenBook, KitchenError } from './kitchen-book.mjs';
import { LOOSE, chapterDoodles, shortName, splitAmount, isPng, ymd, noon } from './kitchen-common.mjs';

export const FORMAT = 1;
const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const ART = join(REPO, 'art');
const EXTRA_ART = ['heart', 'wave', 'tile-az', 'tile-how', 'cover'];
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const slugOf = (s) => String(s).toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'chapter';
// A moment as latest.json writes it: UTC, to the second, always the same shape.
export const stamp = (d = new Date()) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');
const STAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

// Everything in the bundle except latest.json, in a fixed order.
export function buildBundle({ edition = noon(), built = stamp(), kit = loadKitchenBook() } = {}) {
  const { settings, recipes, categories } = kit;
  const cats = categories.filter((c) => recipes.some((r) => r.category === c));
  const loose = recipes.filter((r) => !cats.includes(r.category));
  const names = loose.length ? [...cats, LOOSE] : cats;
  const doodles = chapterDoodles(names, settings.doodles);
  const ids = new Set();
  const chapters = names.map((name) => {
    let id = slugOf(name);
    for (let n = 2; ids.has(id); n++) id = `${slugOf(name)}-${n}`;
    ids.add(id);
    const items = name === LOOSE ? loose : recipes.filter((r) => r.category === name);
    return { id, name, short: name === LOOSE ? LOOSE : shortName(name, settings.short), doodle: doodles.get(name), recipes: items.map((r) => r.slug) };
  });
  const chapterOf = new Map();
  for (const c of chapters) for (const s of c.recipes) chapterOf.set(s, c.id);

  const data = {
    format: FORMAT,
    title: settings.title,
    tagline: settings.tagline,
    footer: settings.footer,
    bundleUrl: settings.bundleUrl,
    settings: { font: settings.font, textSize: settings.textSize, cooking: settings.cooking },
    chapters,
    az: recipes.map((r) => r.slug), // loadKitchenBook sorts them by name
    recipes: Object.fromEntries(recipes.map((r) => [r.slug, {
      title: r.title,
      chapter: chapterOf.get(r.slug),
      aka: r.aka,
      sections: r.sections.map((s) => ({
        heading: s.heading,
        ingredients: s.ingredients.map((line) => { const [amount, text] = splitAmount(line); return { amount, text }; }),
        steps: s.steps,
      })),
      notes: r.notes,
      gap: r.gap,
    }])),
  };

  const files = [{ path: 'recipes.json', data: Buffer.from(JSON.stringify(data) + '\n') }];
  const wanted = [...new Set([...chapters.map((c) => c.doodle), ...EXTRA_ART])].sort();
  for (const name of wanted) {
    let png = null;
    try { png = readFileSync(join(ART, `${name}.png`)); } catch { png = null; }
    if (isPng(png)) files.push({ path: `art/${name}.png`, data: png }); // the app copes without it
  }
  const latest = {
    format: FORMAT,
    edition: ymd(edition),
    built,
    recipes: recipes.length,
    files: files.map((f) => ({ path: f.path, bytes: f.data.length, sha256: sha256(f.data) })),
  };
  return { files, latest, count: recipes.length };
}

// The JSON text of latest.json (written last, so a half-written bundle is never "latest").
export const latestText = (latest) => JSON.stringify(latest, null, 1) + '\n';

// The same files (paths and contents) as an existing latest.json lists?
export function sameFiles(latest, old) {
  if (!old || !Array.isArray(old.files) || old.files.length !== latest.files.length) return false;
  return latest.files.every((f, i) => old.files[i] && old.files[i].path === f.path && old.files[i].sha256 === f.sha256);
}

// Writes the bundle into dir: every file through a temporary name, then latest.json, then tidies
// pictures the new bundle no longer has. When nothing changed, it keeps the old edition's date
// and build time, unless `bump` asks for a new build time (so a Kobo with recipes from a later
// cable install takes these after all: see sync.lua).
export function writeBundle(dir, { edition, built, kit, bump = false } = {}) {
  let old = null;
  try { old = JSON.parse(readFileSync(join(dir, 'latest.json'), 'utf8')); } catch { old = null; }
  let bundle = buildBundle({ edition, built, kit });
  const same = !!old && sameFiles(bundle.latest, old);
  if (same && !bump) {
    const keep = { ...bundle.latest };
    if (/^\d{4}-\d{2}-\d{2}$/.test(old.edition || '')) keep.edition = old.edition;
    if (STAMP.test(old.built || '')) keep.built = old.built;
    // (the same order of keys as a fresh one, so the text stays the same)
    bundle = { ...bundle, latest: keep };
  }
  mkdirSync(join(dir, 'art'), { recursive: true });
  for (const f of bundle.files) {
    const to = join(dir, f.path);
    let unchanged = false;
    try { unchanged = readFileSync(to).equals(f.data); } catch { unchanged = false; }
    if (unchanged) continue;
    writeFileSync(to + '.partial', f.data);
    renameSync(to + '.partial', to);
  }
  writeFileSync(join(dir, 'latest.json.partial'), latestText(bundle.latest));
  renameSync(join(dir, 'latest.json.partial'), join(dir, 'latest.json'));
  const keep = new Set(bundle.files.map((f) => f.path));
  for (const n of readdirSync(join(dir, 'art'))) if (/\.png$/.test(n) && !keep.has(`art/${n}`)) unlinkSync(join(dir, 'art', n));
  return { ...bundle, changed: !same, bumped: same && bump };
}

// A folder we may write a bundle into: missing, empty, or holding only a bundle.
export function bundleFolderProblem(dir) {
  if (!existsSync(dir)) return null;
  if (!statSync(dir).isDirectory()) return `${dir} isn't a folder.`;
  const odd = readdirSync(dir).filter((n) => !['latest.json', 'recipes.json', 'art', '.DS_Store'].includes(n) && !n.endsWith('.partial'));
  const art = join(dir, 'art');
  if (existsSync(art)) {
    if (!statSync(art).isDirectory()) odd.push('art');
    else odd.push(...readdirSync(art).filter((n) => !/\.png$/.test(n) && n !== '.DS_Store' && !n.endsWith('.partial')).map((n) => `art/${n}`));
  }
  return odd.length ? `${dir} has other things in it (${odd.slice(0, 3).join(', ')}${odd.length > 3 ? ', ...' : ''}), so I won't write a bundle there.` : null;
}

// A folder outside this kit (the bundle is built from the kit's own files).
export function outsideKitProblem(dir) {
  const repo = realpathSync.native(REPO);
  let near = resolve(dir);
  while (!existsSync(near) && dirname(near) !== near) near = dirname(near);
  const real = realpathSync.native(near);
  return real === repo || real.startsWith(repo + '/') ? 'Write the bundle outside this kit\'s folder (it is built from it).' : null;
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const USAGE = 'Usage: node tools/kitchen-bundle.mjs --out <folder>';
  const opts = options({ out: { type: 'string' } }, USAGE);
  if (!opts.out) { console.error(USAGE); process.exit(2); }
  const dir = resolve(opts.out);
  const problem = outsideKitProblem(dir) || bundleFolderProblem(dir);
  if (problem) { console.error(problem); process.exit(1); }
  let kit;
  try {
    kit = loadKitchenBook();
  } catch (e) {
    if (!(e instanceof KitchenError)) throw e;
    console.error(e.message);
    process.exit(1);
  }
  for (const note of kit.notes) console.log(note);
  const b = writeBundle(dir, { kit });
  const total = b.latest.files.reduce((a, f) => a + f.bytes, 0);
  console.log(`${b.changed ? 'Wrote' : 'Up to date:'} the recipes of ${b.latest.edition} (${b.count} recipes, ${b.files.length} files, ${Math.round(total / 1024)} KB) in ${dir}`);
}
