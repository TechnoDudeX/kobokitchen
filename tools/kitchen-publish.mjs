#!/usr/bin/env node
// OPTIONAL: Wi-Fi updates. Cable (tools/kobo-install.mjs) is all the kitchen needs; this is only
// for "Get new recipes" on the Kobo, which downloads the recipes from a website of yours.
//
// It writes the recipes bundle (see tools/kitchen-bundle.mjs) into a folder. You put that folder
// on the web, so that it's at book.json's "bundleUrl" (an https:// address). Anyone who knows the
// address can read the recipes there.
//
//   node tools/kitchen-publish.mjs --out <folder>          write the bundle into <folder>
//   node tools/kitchen-publish.mjs --out <folder> --bump   ...and mark it as the newest, even if
//                                                          nothing changed (see below)
//   node tools/kitchen-publish.mjs --check                 read the website the way the Kobo
//                                                          does, and compare it with this kit
//
// <folder> is the one your web host serves at bundleUrl: for example a "kitchen" folder in your
// GitHub Pages repository, if bundleUrl is https://<you>.github.io/<repository>/kitchen/. Then
// upload it (for GitHub Pages: commit and push), and tap How it works > Get new recipes.
//
// Newer only: the Kobo takes the website's recipes only if they were built after the ones it has.
// So recipes put on by cable later than the last publish stay put, instead of being swapped back
// for the website's older ones. To send the Kobo the website's recipes anyway (after going back
// to an older recipes.js, say), publish with --bump and upload again.
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { options } from './args.mjs';
import { loadKitchenBook, KitchenError } from './kitchen-book.mjs';
import { buildBundle, bundleFolderProblem, outsideKitProblem, sameFiles, writeBundle } from './kitchen-bundle.mjs';

const USAGE = `Usage: node tools/kitchen-publish.mjs --out <folder> [--bump]
       node tools/kitchen-publish.mjs --check`;
const opts = options({ out: { type: 'string' }, bump: { type: 'boolean' }, check: { type: 'boolean' } }, USAGE);
const fail = (msg) => { console.error(msg); process.exit(1); };
if (!!opts.check === !!opts.out) fail(USAGE);
if (opts.bump && !opts.out) fail(`--bump goes with --out.\n\n${USAGE}`);

let kit;
try {
  kit = loadKitchenBook();
} catch (e) {
  if (!(e instanceof KitchenError)) throw e;
  fail(e.message);
}
const url = kit.settings.bundleUrl;
if (!url) {
  fail(`book.json has no "bundleUrl", so Wi-Fi updates are off (new recipes go on by cable).
To turn them on, set "bundleUrl" to the https:// address where the published folder will be,
put the recipes on the Kobo by cable once (so it knows the address), then publish.`);
}

if (opts.out) {
  const dir = resolve(opts.out);
  const problem = outsideKitProblem(dir) || bundleFolderProblem(dir);
  if (problem) fail(problem);
  for (const note of kit.notes) console.log(note);
  const b = writeBundle(dir, { kit, bump: !!opts.bump });
  const what = b.bumped ? 'Marked as the newest:' : b.changed ? 'Wrote' : 'Already there:';
  console.log(`${what} the recipes of ${b.latest.edition} (${b.count} recipes, built ${b.latest.built}) in ${dir}`);
  console.log(`
Next: put that folder on the web so that it's at
  ${url}
(for example: commit and push your website). Then check it with
  node tools/kitchen-publish.mjs --check
and tap How it works > Get new recipes on the Kobo.`);
  process.exit(0);
}

/* ---------- --check: the website, read the way the Kobo reads it ---------- */
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
// The Kobo asks for exactly these addresses and follows no redirects, so neither does this.
async function get(address) {
  let res;
  try {
    res = await fetch(address, { redirect: 'manual', headers: { 'Accept-Encoding': 'identity', 'Cache-Control': 'no-cache' } });
  } catch (e) {
    return { error: `couldn't reach it (${e.cause?.code || e.cause?.message || e.message})` };
  }
  if (res.status >= 300 && res.status < 400) {
    return { error: `it redirects (${res.status}) to ${res.headers.get('location') || 'somewhere else'}, and the Kobo doesn't follow redirects: use the final address as bundleUrl` };
  }
  if (res.status !== 200) return { error: `the website answered ${res.status}` };
  return { data: Buffer.from(await res.arrayBuffer()) };
}

console.log(`Reading ${url}latest.json ...`);
const top = await get(`${url}latest.json?t=${Date.now()}`);
if (top.error) fail(`The website isn't ready: ${top.error}.`);
let latest;
try { latest = JSON.parse(top.data.toString('utf8')); } catch { latest = null; }
if (!latest || latest.format !== 1 || !Array.isArray(latest.files)) fail('The website\'s latest.json doesn\'t look like one this kit made.');
let bad = 0;
for (const f of latest.files) {
  const got = await get(`${url}${f.path}?v=${String(f.sha256).slice(0, 16)}`);
  if (got.error) { bad++; console.log(`  ${f.path}: ${got.error}`); continue; }
  if (got.data.length !== f.bytes || sha256(got.data) !== f.sha256) { bad++; console.log(`  ${f.path}: not the file latest.json lists (half uploaded?)`); }
}
if (bad) fail(`${bad} of the website's ${latest.files.length} files can't be used: the Kobo would refuse this edition.`);
console.log(`The website has the recipes of ${latest.edition} (${latest.recipes} recipes, built ${latest.built || '(it doesn\'t say)'}): all ${latest.files.length} files download and check out.`);
const here = buildBundle({ kit });
if (sameFiles(here.latest, latest)) {
  console.log('They are the same as this kit\'s recipes.');
} else {
  console.log(`They differ from this kit's recipes (${here.count} recipes). To put these on the website: node tools/kitchen-publish.mjs --out <folder>, then upload it.`);
}
