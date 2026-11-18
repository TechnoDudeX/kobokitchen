#!/usr/bin/env node
// Puts the kitchen recipe box (a KOReader app) on a Kobo, and later brings its app and its
// recipes up to date, all by cable. Wake the Kobo and plug it into this Mac. Tap "Connect" when
// Kobo's own software asks about the cable ("Share" once the kitchen is on it). If it only
// charges, see "If the Kobo only charges" in the README. Then:
//
//   node tools/kobo-install.mjs
//
// Each part happens only when it's needed, so it's safe to run again:
//  1. Checks it's a Kobo Aura HD (or, with --any-kobo, any Kobo) on Kobo software 4.x, checks
//     the downloads in .cache/koreader, and keeps a copy of Kobo's settings and library on this
//     Mac (.cache/kobo-backup/<date>).
//  2. NickelMenu, the launcher: its installer goes in .kobo/KoboRoot.tgz. Unplugged, the Kobo
//     installs it and restarts, and a "Recipes" button appears at the bottom right of My Books
//     (its one item is in .adds/nm/kitchen).
//  3. KOReader v2026.07.1, in .adds/koreader.
//  4. Kobo's own software is told not to list KOReader's files as books (ExcludeSyncFolders in
//     .kobo/Kobo/Kobo eReader.conf, which is backed up first).
//  5. KOReader's first settings, unless it has its own already: no first-run guide, the cover as
//     the sleep screen, Wi-Fi on without asking, the sleep-cover sensor ignored.
//  6. The kitchen app (kitchen.koplugin, with the handwriting fonts) and its start-up patch.
//  7. The recipes (recipes.js and book.json), swapped in whole, if they changed.
//  8. Ejects the Kobo.
// It never deletes anything that isn't its own: only the kitchen's own kitchen/new and kitchen/old
// folders on the way to swapping new recipes in, and the "._" files macOS leaves next to the
// files it writes there.
//
// Options:
//   --volume <path>     where the Kobo is mounted (default /Volumes/KOBOeReader)
//   --no-eject          leave it mounted (eject it in Finder before unplugging)
//   --update-koreader   put this KOReader on even if the Kobo has a different version
//   --any-kobo          go ahead on a Kobo other than the Aura HD (the only one it was tested on)
//   --dry-run           do it all in a fake Kobo folder instead (it refuses real disks)
//
// To take it all off again: put an empty file named "uninstall" in .adds/nm and restart the
// Kobo (NickelMenu removes itself), then delete .adds/koreader and .adds/nm.
import { closeSync, copyFileSync, existsSync, fsyncSync, mkdirSync, mkdtempSync, openSync, readdirSync,
  readFileSync, realpathSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync, writeSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { options } from './args.mjs';
import { editIni } from './kobo-ini.mjs';
import { loadKitchenBook, KitchenError } from './kitchen-book.mjs';
import { buildBundle, sameFiles, writeBundle } from './kitchen-bundle.mjs';

const USAGE = 'Usage: node tools/kobo-install.mjs [--volume PATH] [--no-eject] [--update-koreader] [--any-kobo] [--dry-run]';
const opts = options({
  volume: { type: 'string' }, 'no-eject': { type: 'boolean' }, 'update-koreader': { type: 'boolean' },
  'any-kobo': { type: 'boolean' }, 'dry-run': { type: 'boolean' },
}, USAGE);

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CACHE = join(ROOT, '.cache', 'koreader');
const PLUGIN = join(ROOT, 'kobo-app', 'kitchen.koplugin');
const PATCHES = join(ROOT, 'kobo-app', 'patches');
const FONTS = join(ROOT, 'fonts');
const KOREADER = {
  file: 'koreader-kobo-v2026.07.1.zip', version: 'v2026.07.1',
  sha256: '0f36a62ce73b12516f969e4ad7862cc06920afb03c7bd4db29a0d990bdd84b2f',
  url: 'https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-kobo-v2026.07.1.zip',
};
const NICKELMENU = {
  file: 'NickelMenu-v0.6.0-KoboRoot.tgz', version: 'v0.6.0',
  sha256: '322ff9aa863860e8f5f7e0b55cae561c54bf95983b9bce1d19819d1225d064af',
  url: 'https://github.com/pgaskin/NickelMenu/releases/download/v0.6.0/KoboRoot.tgz',
};
const AURA_HD = '00000000-0000-0000-0000-000000000350';
const LATEST = '4.38.23684';
const ON_KOBO = '/mnt/onboard/.adds/koreader';
// Kobo's software lists every file it finds as a book, in hidden folders too (since 4.17); this
// keeps it out of every hidden folder but its own (as the KOReader wiki gives it: in the file
// itself the backslashes are doubled).
const EXCLUDE = { FeatureSettings: { ExcludeSyncFolders: '(\\\\.(?!kobo|adobe).+|([^.][^/]*/)+\\\\..+)' } };
const NM_CONFIG = `# The kitchen recipe box (made by tools/kobo-install.mjs): the button that starts the kitchen.
menu_item:main:Recipes:cmd_spawn:quiet:exec ${ON_KOBO}/koreader.sh
experimental:menu_main_15505_label:Recipes
`;
// KOReader's first settings: a Lua table, as KOReader writes it. (The plugin and its start-up
// patch put the important ones right at every start too.)
const SETTINGS = `-- ./settings.reader.lua (first settings, from tools/kobo-install.mjs)
return {
    ["auto_restore_wifi"] = false,
    ["autoshutdown_timeout_seconds"] = 2419200,
    ["ignore_power_sleepcover"] = true,
    ["plugins_disabled"] = {
        ["coverbrowser"] = true,
    },
    ["quickstart_shown_version"] = 202607010000,
    ["screensaver_document_cover"] = "${ON_KOBO}/kitchen/current/art/cover.png",
    ["screensaver_hide_fallback_msg"] = false,
    ["screensaver_show_message"] = false,
    ["screensaver_type"] = "document_cover",
    ["start_with"] = "filemanager",
    ["wifi_disable_action"] = "turn_off",
    ["wifi_enable_action"] = "turn_on",
}
`;

const dryRun = !!opts['dry-run'];
const FAKE_DEFAULT = join(tmpdir(), 'kobo-kitchen-fake-kobo-install');
const FAKE_MARK = '.kobo-kitchen-fake-kobo';
const root = resolve(opts.volume || (dryRun ? FAKE_DEFAULT : '/Volumes/KOBOeReader'));
const realDisk = /^\/Volumes\/[^/]+$/.test(root);
const written = []; // files written on the Kobo (macOS may leave a "._" file next to each)
let changedAnything = false;

const step = (title) => console.log(`\n== ${title}`);
const note = (msg) => console.log(`   ${msg}`);
function fail(msg) {
  console.error(`\n${msg}${changedAnything ? '' : '\n(Nothing on the Kobo was changed.)'}`);
  process.exit(1);
}
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

// Writes a file through a temporary name and makes sure it's on the disk before it takes the
// real name, so a pulled cable never leaves half a file.
function writeSafe(path, data) {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = path + '.kitchen-partial';
  const fd = openSync(tmp, 'w');
  try {
    for (let at = 0; at < buf.length;) at += writeSync(fd, buf, at, buf.length - at);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, path);
  written.push(path);
  changedAnything = true;
}

// Writes a file only if it's different. True if it wrote.
function put(path, data) {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  let old = null;
  try { old = readFileSync(path); } catch { old = null; }
  if (old && old.equals(buf)) return false;
  writeSafe(path, buf);
  return true;
}

// Copies one of our folders file by file (only what changed). How many files it wrote.
function putTree(src, dst) {
  let n = 0;
  for (const name of readdirSync(src)) {
    if (name.startsWith('.')) continue;
    const s = join(src, name), d = join(dst, name);
    if (statSync(s).isDirectory()) n += putTree(s, d);
    else if (put(d, readFileSync(s))) n++;
  }
  return n;
}

// macOS keeps notes about the files it writes on a disk like the Kobo's in hidden "._" files.
// They're no use there; this tidies them away inside a folder of ours.
function tidyTree(dir) {
  let n = 0;
  let names = [];
  try { names = readdirSync(dir); } catch { return 0; }
  for (const name of names) {
    const p = join(dir, name);
    if (name.startsWith('._')) {
      try { unlinkSync(p); n++; } catch { /* already gone */ }
      continue;
    }
    let st = null;
    try { st = statSync(p); } catch { st = null; }
    if (st && st.isDirectory()) n += tidyTree(p);
  }
  return n;
}

function eject() {
  if (dryRun || !realDisk || opts['no-eject']) return false;
  try { execFileSync('diskutil', ['eject', root], { stdio: 'ignore' }); return true; } catch { return false; }
}

/* ---------- 1. find the Kobo, and check everything before touching it ---------- */
if (dryRun) {
  // A dry run must never write to a real Kobo: refuse any path on the disks under /Volumes (macOS
  // ignores case, and /Volumes is also /System/Volumes/Data/Volumes), and anywhere inside a folder
  // that has a .kobo the dry run didn't make.
  const onVolumes = (p) => /^(\/system\/volumes\/data)?\/volumes(\/|$)/i.test(p);
  let near = root;
  while (!existsSync(near) && dirname(near) !== near) near = dirname(near);
  try { near = realpathSync.native(near); } catch { /* keep it as typed */ }
  if (onVolumes(root) || onVolumes(near)) {
    fail(`--dry-run won't use ${root}: that's where real disks (like the Kobo) are mounted.
  Leave out --volume, or give a fresh folder somewhere else.`);
  }
  for (let at = root; ; at = dirname(at)) {
    const ours = at === root && (existsSync(join(at, FAKE_MARK)) || at === resolve(FAKE_DEFAULT));
    if (existsSync(join(at, '.kobo')) && !ours) {
      fail(`--dry-run won't use ${root}: ${at === root ? 'it' : `${at}, a folder it's in,`} has a .kobo folder that a dry run didn't
  make, so it might be a real Kobo. Leave out --volume, or give a fresh folder.`);
    }
    if (dirname(at) === at) break;
  }
  console.log(`Dry run: using the fake Kobo folder ${root} (nothing else is touched)`);
  mkdirSync(join(root, '.kobo', 'Kobo'), { recursive: true });
  writeFileSync(join(root, FAKE_MARK), 'Made by tools/kobo-install.mjs --dry-run. Not a real Kobo.\n');
  if (!existsSync(join(root, '.kobo', 'version'))) {
    writeFileSync(join(root, '.kobo', 'version'), `N000000000000,0.0.0,${LATEST},0.0.0,0.0.0,${AURA_HD}\n`);
  }
  if (!existsSync(join(root, '.kobo', 'Kobo', 'Kobo eReader.conf'))) {
    writeFileSync(join(root, '.kobo', 'Kobo', 'Kobo eReader.conf'), '[ApplicationPreferences]\nSideloadedMode=true\n');
  }
} else if (!existsSync(join(root, '.kobo'))) {
  fail(`I can't find the Kobo${existsSync(root) ? ` (${root} is there, but it doesn't look like a Kobo)` : ''}.

  1. Wake the Kobo, then plug it into this Mac with its USB cable.
  2. On the Kobo, tap "Connect" (in Kobo's own software) or "Share" (in the kitchen).
     If nothing asks: plugged straight into a USB-C MacBook, an older Kobo can take the Mac for
     a charger. If the kitchen is on it already, hold a finger on its big title and choose
     "Connect to computer", then "Connect". Otherwise plug it in through a USB hub, with a
     USB-A-to-micro-USB cable.
  3. If the Mac asks to allow the accessory, click Allow. Wait until "KOBOeReader" shows up in
     Finder, then run this again. (If it never does, unplug the Kobo: the kitchen comes back.)

  (If it's mounted under another name, add --volume /Volumes/<name>.)`);
}

step('The Kobo');
let fields = [];
try { fields = readFileSync(join(root, '.kobo', 'version'), 'latin1').trim().split(','); } catch { fields = []; }
const firmware = /^\d+(\.\d+)+$/.test(fields[2] || '') ? fields[2] : null;
const model = (fields[5] || '').trim();
const auraHd = model === AURA_HD;
if (!auraHd && !opts['any-kobo']) {
  fail(`This doesn't look like a Kobo Aura HD (its model number is ${model || 'unreadable'}). The kit was only tested on
  the Aura HD. KOReader and NickelMenu run on most Kobos, so it will probably work, but nobody
  has tried: to go ahead anyway, run this again with --any-kobo.`);
}
if (!firmware || !firmware.startsWith('4.')) {
  fail(`It has Kobo software ${firmware || '(unreadable)'}, and this needs 4.x (it was tested with ${LATEST}).`);
}
note(`${auraHd ? 'Kobo Aura HD' : `A Kobo (model ${model || 'unknown'}; only the Aura HD was tested)`}, with Kobo software ${firmware}.`);

step('The downloads');
const downloads = {};
for (const d of [KOREADER, NICKELMENU]) {
  const p = join(CACHE, d.file);
  if (!existsSync(p)) fail(`${d.file} isn't in ${CACHE}. Download it from\n  ${d.url}\ninto that folder (as ${d.file}), then run this again.`);
  const data = readFileSync(p);
  if (sha256(data) !== d.sha256) fail(`${p} isn't the right file (its SHA-256 differs). Download it again from\n  ${d.url}`);
  downloads[d.file] = data;
}
note(`KOReader ${KOREADER.version} and NickelMenu ${NICKELMENU.version} are here and check out.`);

const nmInstalled = existsSync(join(root, '.adds', 'nm', 'doc'));
const waiting = join(root, '.kobo', 'KoboRoot.tgz');
const nmWaiting = existsSync(waiting) && readFileSync(waiting).equals(downloads[NICKELMENU.file]);
if (!nmInstalled && existsSync(waiting) && !nmWaiting) {
  fail(`Another update is already waiting on the Kobo (.kobo/KoboRoot.tgz). Eject and unplug the Kobo, let it
  install that first (it restarts by itself), then run this again.`);
}

let kit;
try {
  kit = loadKitchenBook();
} catch (e) {
  if (!(e instanceof KitchenError)) throw e;
  fail(e.message);
}

/* ---------- 2. a copy of Kobo's settings and library, on this Mac ---------- */
step('A copy of Kobo\'s settings and library, on this Mac');
const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
const backup = join(dryRun ? join(tmpdir(), 'kobo-kitchen-fake-backups') : join(ROOT, '.cache', 'kobo-backup'), stamp);
let saved = 0;
for (const sub of ['.kobo', join('.kobo', 'Kobo'), join('.adds', 'nm')]) {
  const dir = join(root, sub);
  if (!existsSync(dir)) continue;
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    let st = null;
    try { st = statSync(p); } catch { st = null; }
    if (name.startsWith('._') || !st || !st.isFile()) continue;
    mkdirSync(join(backup, sub), { recursive: true });
    copyFileSync(p, join(backup, sub, name));
    saved++;
  }
}
note(`${saved} files kept in ${dryRun ? backup : relative(ROOT, backup)}`);

/* ---------- 3. NickelMenu, the launcher ---------- */
step(`NickelMenu ${NICKELMENU.version} (the launcher)`);
if (nmInstalled) {
  note('Already installed.');
} else if (nmWaiting) {
  note('Its installer is already waiting: the Kobo installs it when it\'s unplugged.');
} else {
  writeSafe(waiting, downloads[NICKELMENU.file]);
  note('Added its installer (.kobo/KoboRoot.tgz): unplugged, the Kobo installs it and restarts.');
}
if (put(join(root, '.adds', 'nm', 'kitchen'), NM_CONFIG)) note('Added the "Recipes" button (.adds/nm/kitchen).');
else note('The "Recipes" button is set up.');

/* ---------- 4. KOReader ---------- */
step(`KOReader ${KOREADER.version}`);
const koDir = join(root, '.adds', 'koreader');
let haveVersion = null;
try { haveVersion = readFileSync(join(koDir, 'git-rev'), 'utf8').trim(); } catch { haveVersion = null; }
const haveKoreader = existsSync(join(koDir, 'koreader.sh'));
if (haveKoreader && haveVersion === KOREADER.version) {
  note('Already there.');
} else if (haveKoreader && !opts['update-koreader']) {
  note(`The Kobo has KOReader ${haveVersion || '(of an unknown version)'}: leaving it as it is (--update-koreader puts ${KOREADER.version} on).`);
} else {
  const tmp = mkdtempSync(join(tmpdir(), 'kitchen-koreader-'));
  try {
    execFileSync('unzip', ['-q', join(CACHE, KOREADER.file), 'koreader/*', '-d', tmp], { stdio: 'inherit' });
    note(`Copying it to the Kobo (about 90 MB: a minute or two)...`);
    mkdirSync(koDir, { recursive: true });
    changedAnything = true;
    // ditto merges it into the folder (KOReader's settings and our plugin stay), without macOS's notes
    execFileSync('ditto', ['--norsrc', '--noextattr', '--noacl', join(tmp, 'koreader'), koDir], { stdio: 'inherit' });
    // a quick check that it all landed: every file there, at its size
    const missing = [];
    const walk = (from, rel) => {
      for (const name of readdirSync(from)) {
        const s = join(from, name);
        const st = statSync(s);
        if (st.isDirectory()) walk(s, join(rel, name));
        else {
          let d = null;
          try { d = statSync(join(koDir, rel, name)); } catch { d = null; }
          if (!d || d.size !== st.size) missing.push(join(rel, name));
        }
      }
    };
    walk(join(tmp, 'koreader'), '');
    if (missing.length) fail(`${missing.length} of KOReader's files didn't copy properly (${missing.slice(0, 3).join(', ')}...). Is the Kobo still plugged in? Run this again.`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  note(`Put KOReader ${KOREADER.version} in .adds/koreader.`);
}

/* ---------- 5. keep KOReader's files out of My Books ---------- */
step('Keeping KOReader\'s files out of My Books');
const kconf = join(root, '.kobo', 'Kobo', 'Kobo eReader.conf');
const before = existsSync(kconf) ? readFileSync(kconf) : Buffer.alloc(0);
const after = Buffer.from(editIni(before.toString('latin1'), EXCLUDE), 'latin1');
if (after.equals(before)) {
  note('Already set.');
} else {
  const bak = kconf + '.kitchen-backup';
  if (before.length && !existsSync(bak)) {
    copyFileSync(kconf, bak);
    written.push(bak);
    note(`Backed up Kobo's settings as ${relative(root, bak)}.`);
  }
  writeSafe(kconf, after);
  note('Set ExcludeSyncFolders in .kobo/Kobo/Kobo eReader.conf.');
}

/* ---------- 6. KOReader's first settings ---------- */
step('KOReader\'s first settings');
const settingsFile = join(koDir, 'settings.reader.lua');
if (existsSync(settingsFile)) {
  note('KOReader has its own settings already: leaving them (the kitchen puts right what it needs).');
} else {
  writeSafe(settingsFile, SETTINGS);
  note('Added them: no first-run guide, the cover as the sleep screen, Wi-Fi on without asking.');
}

/* ---------- 7. the kitchen app ---------- */
step('The kitchen app');
const pluginDir = join(koDir, 'plugins', 'kitchen.koplugin');
let n = putTree(PLUGIN, pluginDir);
for (const f of readdirSync(FONTS)) {
  if (/\.(ttf|txt)$/.test(f) && put(join(pluginDir, 'fonts', f), readFileSync(join(FONTS, f)))) n++;
}
for (const f of readdirSync(PATCHES)) {
  if (f.endsWith('.lua') && put(join(koDir, 'patches', f), readFileSync(join(PATCHES, f)))) n++;
}
note(n ? `${n} file${n === 1 ? '' : 's'} added or updated.` : 'Already up to date.');

/* ---------- 8. the recipes ---------- */
step('The recipes');
for (const msg of kit.notes) note(msg);
const kdir = join(koDir, 'kitchen');
const cur = join(kdir, 'current'), fresh = join(kdir, 'new'), old = join(kdir, 'old');
let curLatest = null;
try { curLatest = JSON.parse(readFileSync(join(cur, 'latest.json'), 'utf8')); } catch { curLatest = null; }
const built = buildBundle({ kit });
if (curLatest && sameFiles(built.latest, curLatest)) {
  note(`Already there: the recipes of ${curLatest.edition} (${built.count} recipes).`);
} else {
  // Built whole in kitchen/new, checked, then swapped in: current -> old, new -> current. (The
  // kitchen puts a swap that was cut off right when it next starts.)
  rmSync(fresh, { recursive: true, force: true });
  changedAnything = true;
  const b = writeBundle(fresh, { kit });
  for (const f of b.latest.files) {
    let back = null;
    try { back = readFileSync(join(fresh, f.path)); } catch { back = null; }
    if (!back || sha256(back) !== f.sha256) fail(`The recipes didn't copy properly (${f.path}). Is the Kobo still plugged in? Run this again.`);
  }
  rmSync(old, { recursive: true, force: true });
  if (existsSync(cur)) renameSync(cur, old);
  renameSync(fresh, cur);
  rmSync(old, { recursive: true, force: true });
  note(`Put on the recipes of ${b.latest.edition} (${b.count} recipes).`);
}

/* ---------- 9. tidy up and eject ---------- */
let tidied = tidyTree(koDir) + tidyTree(join(root, '.adds', 'nm'));
for (const p of written) {
  const side = join(dirname(p), `._${basename(p)}`);
  if (existsSync(side)) { try { unlinkSync(side); tidied++; } catch { /* already gone */ } }
}
for (const d of [join(root, '.adds', '._koreader'), join(root, '.adds', '._nm'), join(root, '._.adds')]) {
  if (existsSync(d)) { try { unlinkSync(d); tidied++; } catch { /* already gone */ } }
}
if (tidied) note(`(Tidied away ${tidied} of macOS's "._" files.)`);

const ejected = eject();
if (dryRun) {
  console.log(`\n== Dry run finished: everything went into ${root}`);
  process.exit(0);
}
console.log(`\n${changedAnything ? 'Done!' : 'All set: nothing needed changing.'}${ejected ? ' Ejected the Kobo: you can unplug it.' : ''}`);
if (!ejected && realDisk) console.log(`Eject "${basename(root)}" in Finder before unplugging.`);
if (haveKoreader && nmInstalled) {
  // An update: KOReader was running and shared its storage, so it starts again by itself.
  console.log(`
On the Kobo: unplug it. If the kitchen was open when you plugged it in, KOReader starts again by
itself and opens it${changedAnything ? ' with the changes' : ''}. If it shows My Books instead, tap "Recipes" at the bottom
right, then "Recipes".`);
} else {
  console.log(`
On the Kobo:${nmInstalled ? '' : `
  - After unplugging, it installs NickelMenu and restarts by itself. Wait for My Books. (If it
    doesn't restart, switch it off and on again with the power switch.)`}
  - Tap "Recipes" at the bottom right, then "Recipes" in the little menu. KOReader starts (the
    first time takes a little longer) and opens "${kit.settings.title}".${kit.settings.bundleUrl ? `
  - Wi-Fi (for Get new recipes), once: hold a finger on the big title "${kit.settings.title}", then
    "Wi-Fi setup". Pick your Wi-Fi (a 2.4 GHz one) and type its password. Then try How it works >
    Get new recipes.` : ''}
  - Don't switch the Kobo off within 20 seconds of switching it on: NickelMenu takes that as a
    sign it broke something, and uninstalls itself.`);
}
