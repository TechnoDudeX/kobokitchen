#!/usr/bin/env node
// Runs the Kobo app on this Mac, in KOReader for macOS, and saves a picture of every screen in
// preview/ (1080 x 1440 grey, like the Kobo Aura HD). A quick way to see your recipes and
// settings before they go on the Kobo.
//
//   node tools/kitchen-preview.mjs [--app KOReader.app] [--window] [--recipe SLUG]
//                                  [--stale | --test-wifi]
//
// --app        where KOReader for macOS is (default .cache/koreader/KOReader.app; see the README)
// --window     show it in a window instead (540 x 720 points: 1080 x 1440 pixels on Retina)
// --recipe     also take pictures of this recipe (its slug, as in book.json's "hidden")
// --stale      (Wi-Fi updates only) start the preview's Kobo with one recipe missing, so its
//              "Get new recipes" step really downloads from your website (book.json's
//              bundleUrl), checks every file, swaps them in, and reports the new one
// --test-wifi  try "Get new recipes" without a website: a stand-in website (a folder on this Mac)
//              answers instead, first with newer recipes, then with older ones (which the Kobo
//              must keep its own over), the same ones, and older ones made newest with --bump
//
// It builds a throwaway KOReader profile in .cache/preview-home: the plugin with its fonts, the
// recipes bundle, the kiosk patch, and a driver patch (tools/kitchen-preview.lua) that walks
// through the screens (with real taps, holds and swipes for the ways in) and saves each one.
// KOReader runs with no window (SDL's "dummy" video driver) at the Aura HD's size. Every picture
// is checked for size; preview/preview-steps.txt says what happened at each step.
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { options } from './args.mjs';
import { loadKitchenBook, KitchenError } from './kitchen-book.mjs';
import { stamp, writeBundle } from './kitchen-bundle.mjs';

const USAGE = 'Usage: node tools/kitchen-preview.mjs [--app KOReader.app] [--window] [--recipe SLUG] [--stale | --test-wifi]';
const opts = options({
  app: { type: 'string' }, window: { type: 'boolean' }, stale: { type: 'boolean' }, 'test-wifi': { type: 'boolean' },
  recipe: { type: 'string' },
}, USAGE);
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const APP = resolve(opts.app || join(ROOT, '.cache', 'koreader', 'KOReader.app'));
const EXE = join(APP, 'Contents', 'MacOS', 'koreader');
const HOME = join(ROOT, '.cache', 'preview-home');
const SITE = join(ROOT, '.cache', 'preview-site');
const OUT = join(ROOT, 'preview');
const FAKE_URL = 'https://kitchen-preview.invalid/'; // never looked up: the driver answers for it
const fail = (msg) => { console.error(msg); process.exit(1); };

if (!existsSync(EXE)) fail(`KOReader for Mac isn't at ${APP}.\nSee "The Mac preview" in the README for where to get it (or use --app <KOReader.app>).`);
if (/['"]/.test(HOME + OUT)) fail(`The kit's path has a quote in it, which KOReader can't take: ${ROOT}`);
if (opts.stale && opts['test-wifi']) fail(`--stale and --test-wifi don't go together.\n\n${USAGE}`);

let kit;
try {
  kit = loadKitchenBook();
} catch (e) {
  if (!(e instanceof KitchenError)) throw e;
  fail(e.message);
}
if (opts.stale && !kit.settings.bundleUrl) fail('--stale gets new recipes from your website, and book.json has no "bundleUrl". (--test-wifi needs none.)');
if ((opts.stale || opts['test-wifi']) && kit.recipes.length < 2) fail('That needs at least two recipes.');

// A fresh profile every time (KOReader also remembers its window size in it).
rmSync(HOME, { recursive: true, force: true });
rmSync(SITE, { recursive: true, force: true });
for (const d of ['plugins', 'patches', 'books', 'kitchen/current']) mkdirSync(join(HOME, d), { recursive: true });
const plugin = join(HOME, 'plugins', 'kitchen.koplugin');
cpSync(join(ROOT, 'kobo-app', 'kitchen.koplugin'), plugin, { recursive: true });
mkdirSync(join(plugin, 'fonts'), { recursive: true });
for (const f of readdirSync(join(ROOT, 'fonts'))) {
  if (/\.(ttf|txt)$/.test(f)) cpSync(join(ROOT, 'fonts', f), join(plugin, 'fonts', f));
}
for (const f of readdirSync(join(ROOT, 'kobo-app', 'patches'))) {
  if (f.endsWith('.lua')) cpSync(join(ROOT, 'kobo-app', 'patches', f), join(HOME, 'patches', f));
}
writeFileSync(join(HOME, 'patches', '2-zz-kitchen-preview.lua'), readFileSync(join(ROOT, 'tools', 'kitchen-preview.lua')));

let b;
if (opts['test-wifi']) {
  // The stand-in website answers at FAKE_URL. The preview's Kobo starts with the last recipe in
  // A to Z missing (built long ago); the website comes in three versions: newer (all of them,
  // built now), older (without that recipe, built just after the Kobo's), and bumped (without it,
  // but built after everything else, as kitchen-publish.mjs --bump would make it).
  const online = { ...kit, settings: { ...kit.settings, bundleUrl: FAKE_URL } };
  const fewer = { ...online, recipes: online.recipes.slice(0, -1) };
  b = writeBundle(join(HOME, 'kitchen', 'current'), { kit: fewer, edition: new Date(2026, 0, 1, 12), built: '2026-01-01T12:00:00Z' });
  writeBundle(join(SITE, 'newer'), { kit: online });
  writeBundle(join(SITE, 'older'), { kit: fewer, edition: new Date(2026, 0, 2, 12), built: '2026-01-02T12:00:00Z' });
  writeBundle(join(SITE, 'bumped'), { kit: fewer, built: stamp(new Date(Date.now() + 3600 * 1000)) });
  console.log(`(--test-wifi: the preview's Kobo starts without "${kit.recipes[kit.recipes.length - 1].title}"; a stand-in website answers at ${FAKE_URL})`);
} else {
  // --stale: the preview's Kobo starts without the last recipe in A to Z (and an older date).
  const left = opts.stale ? kit.recipes[kit.recipes.length - 1] : null;
  b = writeBundle(join(HOME, 'kitchen', 'current'), left
    ? { kit: { ...kit, recipes: kit.recipes.slice(0, -1) }, edition: new Date(2026, 0, 1, 12), built: '2026-01-01T12:00:00Z' }
    : { kit });
  if (left) console.log(`(--stale: the preview's Kobo starts without "${left.title}".)`);
}
writeFileSync(join(HOME, 'settings.reader.lua'), `-- ./settings.reader.lua
return {
    ["color_rendering"] = false,
    ["home_dir"] = ${JSON.stringify(join(HOME, 'books'))},
    ["quickstart_shown_version"] = 202607010000,
    ["start_with"] = "filemanager",
}
`);

mkdirSync(OUT, { recursive: true });
for (const f of readdirSync(OUT)) if (/\.(png|txt)$/.test(f)) rmSync(join(OUT, f));

const env = {
  ...process.env,
  KO_HOME: HOME,
  KITCHEN_PREVIEW_OUT: OUT,
  KITCHEN_PREVIEW_RECIPE: opts.recipe || '',
  KITCHEN_PREVIEW_SITE: opts['test-wifi'] ? SITE : '',
  EMULATE_READER_DPI: '265',
  EMULATE_BW_SCREEN: '1',
  EMULATE_BB_TYPE: 'BB8',
};
if (opts.window) {
  Object.assign(env, { EMULATE_READER_W: '540', EMULATE_READER_H: '720' });
} else {
  Object.assign(env, { EMULATE_READER_W: '1080', EMULATE_READER_H: '1440', SDL_VIDEO_DRIVER: 'dummy' });
}
console.log(`Running KOReader with the recipes of ${b.latest.edition} (${b.count} recipes)${opts.window ? ' in a window' : ''}...`);
const run = spawnSync(EXE, [], { env, cwd: HOME, encoding: 'utf8', timeout: 240000, maxBuffer: 64 * 1024 * 1024 });
const log = `${run.stdout || ''}\n${run.stderr || ''}`;
writeFileSync(join(OUT, 'koreader-log.txt'), log);
if (run.error) console.error(`KOReader didn't finish: ${run.error.message}`);
const worrying = log.split('\n').filter((l) => /kitchen|error|traceback|stack|attempt to|failed|not supported|SDL using|video driver/i.test(l) && !/kitchen-preview: /.test(l));
if (worrying.length) console.log(`From KOReader's log (all of it: preview/koreader-log.txt):\n  ${worrying.slice(0, 60).join('\n  ')}`);

// Every picture should be the Aura HD's size.
const pngs = readdirSync(OUT).filter((f) => f.endsWith('.png')).sort();
let wrong = 0;
for (const f of pngs) {
  const d = readFileSync(join(OUT, f));
  const w = d.readUInt32BE(16), h = d.readUInt32BE(20);
  if (w !== 1080 || h !== 1440) { wrong++; console.log(`  ${f} is ${w} x ${h}, not 1080 x 1440`); }
}
const steps = existsSync(join(OUT, 'preview-steps.txt')) ? readFileSync(join(OUT, 'preview-steps.txt'), 'utf8') : '';
if (steps) console.log(`\nWhat the preview did:\n${steps.trimEnd().split('\n').map((l) => `  ${l}`).join('\n')}`);
const failed = /FAILED/.test(steps);
console.log(`\n${pngs.length} pictures in ${OUT}${wrong ? `, ${wrong} of the wrong size` : ''}${failed ? ', and a step FAILED' : ''}. KOReader exited with ${run.status}.`);
process.exit(run.status === 0 && pngs.length && !wrong && !failed ? 0 : 1);
