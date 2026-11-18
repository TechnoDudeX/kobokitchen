// The kitchen's recipes and settings: recipes.js (the master copy of the recipes) and book.json
// (the title, the words on the screens, the look, the chapter order and, optionally, the
// website for Wi-Fi updates), checked and put in the book's order. Every tool starts here.
//
//   loadKitchenBook() -> {
//     book,        book.json as written
//     settings,    book.json with every default filled in
//     all,         every recipe in recipes.js (the kitchen's shape, see load-recipes.mjs)
//     recipes,     the ones that go on the Kobo: not hidden, sorted by title
//     categories,  chapter names in order: categoryOrder, then any new ones
//     notes,       things worth saying (each one line or a short paragraph)
//   }
// Throws KitchenError, with a message ready to show, when book.json or recipes.js has a problem.
import { existsSync, readFileSync } from 'node:fs';
import { kitchenRecipes } from './load-recipes.mjs';
import { LOOSE } from './kitchen-common.mjs'; // the last chapter, for recipes with no category

export class KitchenError extends Error {}
export const BOOK_JSON = new URL('../book.json', import.meta.url);
const ART = new URL('../art/', import.meta.url);

const KNOWN = ['title', 'tagline', 'footer', 'textSize', 'font', 'cooking', 'categoryOrder', 'short', 'doodles',
  'hidden', 'bundleUrl', 'cover'];

// book.json's bundleUrl as the Kobo wants it: an https:// address ending in "/", or '' for none.
export function bundleUrlOf(value) {
  const v = String(value ?? '').trim();
  if (!v) return '';
  let u;
  try { u = new URL(v); } catch { u = null; }
  if (!u || u.protocol !== 'https:' || u.search || u.hash || u.username || u.password || /\s/.test(v)) {
    throw new KitchenError(`book.json: "bundleUrl" must be an https:// address with nothing after a "?" or "#" (it's ${JSON.stringify(v)}).
  Leave it as "" to keep Wi-Fi updates off.`);
  }
  return u.href.endsWith('/') ? u.href : `${u.href}/`;
}

const isObject = (v) => !!v && typeof v === 'object' && !Array.isArray(v);

export function loadKitchenBook() {
  let book;
  try {
    book = JSON.parse(readFileSync(BOOK_JSON, 'utf8'));
  } catch (e) {
    throw new KitchenError(`Couldn't read book.json (${e.message}).`);
  }
  if (!isObject(book)) throw new KitchenError('book.json should be one { ... } block of settings.');
  // Allowed values are shown as they are written in the file: "normal" in quotes, true without.
  const oneOf = (key, allowed) => {
    if (book[key] !== undefined && !allowed.includes(book[key])) {
      throw new KitchenError(`book.json: "${key}" must be one of ${allowed.map((a) => JSON.stringify(a)).join(', ')}.`);
    }
  };
  oneOf('textSize', ['normal', 'large', 'huge']);
  oneOf('font', ['handwriting', 'plain']);
  oneOf('cooking', [true, false]);
  for (const key of ['title', 'tagline', 'footer', 'bundleUrl']) {
    if (book[key] !== undefined && typeof book[key] !== 'string') throw new KitchenError(`book.json: "${key}" must be words in quotes.`);
  }
  for (const key of ['categoryOrder', 'hidden']) {
    if (book[key] !== undefined && !(Array.isArray(book[key]) && book[key].every((x) => typeof x === 'string'))) {
      throw new KitchenError(`book.json: "${key}" must be a list of names in quotes.`);
    }
  }
  if (book.short !== undefined && !(isObject(book.short) && Object.values(book.short).every((x) => typeof x === 'string'))) {
    throw new KitchenError('book.json: "short" must look like { "Soups & Stews": "Soups", ... }.');
  }
  if (book.doodles !== undefined && !(isObject(book.doodles) && Object.values(book.doodles).every((x) => typeof x === 'string' && /^[a-z0-9-]+$/.test(x)))) {
    throw new KitchenError('book.json: "doodles" must look like { "Soups & Stews": "bowl", ... } (the name of a picture in art/, without ".png").');
  }
  if (book.cover !== undefined && !(isObject(book.cover) && Object.values(book.cover).every((x) => typeof x === 'string'))) {
    throw new KitchenError('book.json: "cover" must look like { "top": "recipes from", "tagline": "...", "bottom": "made with love {heart}" }.');
  }

  const notes = [];
  const unknown = Object.keys(book).filter((k) => !KNOWN.includes(k));
  if (unknown.length) notes.push(`Note: book.json has ${unknown.map((k) => `"${k}"`).join(', ')}, which the kitchen doesn't use (a typo?).`);
  const order = book.categoryOrder || [];
  const twice = order.filter((c, i) => order.indexOf(c) !== i);
  if (twice.length) notes.push(`Note: book.json lists ${[...new Set(twice)].map((c) => `"${c}"`).join(', ')} more than once in "categoryOrder"; the first place counts.`);
  for (const [chapter, name] of Object.entries(book.doodles || {})) {
    if (!existsSync(new URL(`${name}.png`, ART))) notes.push(`Note: book.json gives "${chapter}" the doodle "${name}", but there's no art/${name}.png.`);
  }
  const settings = {
    title: book.title || 'Recipe Box', tagline: book.tagline || '', footer: book.footer || '',
    textSize: book.textSize || 'normal', font: book.font || 'handwriting', cooking: book.cooking !== false,
    short: book.short || {}, doodles: book.doodles || {}, hidden: book.hidden || [],
    bundleUrl: bundleUrlOf(book.bundleUrl), cover: book.cover || {},
  };

  let all;
  try {
    all = kitchenRecipes().recipes;
  } catch (e) {
    throw new KitchenError(`Couldn't read recipes.js (${e.message}). Is there a typo in it?`);
  }
  const problems = [];
  const slugs = new Set();
  for (const r of all) {
    if (!r.title || !r.slug) problems.push('a recipe has no name');
    else if (slugs.has(r.slug)) problems.push(`two recipes are called "${r.title}"`);
    slugs.add(r.slug);
  }
  if (problems.length) throw new KitchenError(`recipes.js has a problem:\n${problems.map((p) => `  - ${p}`).join('\n')}`);

  const hidden = new Set(settings.hidden);
  for (const s of hidden) if (!slugs.has(s)) notes.push(`Note: book.json hides "${s}", but no recipe has that slug.`);
  const recipes = all
    .filter((r) => !r.hidden && !hidden.has(r.slug))
    .sort((a, b) => a.title.localeCompare(b.title, 'en', { sensitivity: 'base' }) || (a.slug < b.slug ? -1 : 1));
  if (!recipes.length) throw new KitchenError('Every recipe is hidden from the Kobo, so there is nothing to put on it.');
  if (recipes.length < all.length) notes.push(`Leaving ${all.length - recipes.length} hidden recipe(s) off the Kobo.`);
  const fresh = [...new Set(recipes.map((r) => r.category).filter((c) => c && !order.includes(c)))];
  if (fresh.length) {
    notes.push(`New chapter${fresh.length > 1 ? 's' : ''}: ${fresh.join(', ')}. ${fresh.length > 1 ? 'They go' : 'It goes'} at the end, with a doodle picked
  for ${fresh.length > 1 ? 'them' : 'it'}. To choose the place, add ${fresh.length > 1 ? 'them' : 'it'} to "categoryOrder" in book.json.`);
  }
  const loose = recipes.filter((r) => !r.category);
  if (loose.length) {
    notes.push(`Note: ${loose.length === 1 ? `"${loose[0].title}" has` : `${loose.length} recipes have`} no category in recipes.js, so ${loose.length === 1 ? 'it goes' : 'they go'} in a
  last chapter called "${LOOSE}".`);
  }
  // The Kobo shows each step, note or "gap" whole, on one page (and a step on one screen in
  // cooking mode), so a very long one would run off the bottom.
  const LONG = 450;
  for (const r of recipes) {
    const texts = [...r.sections.flatMap((s) => s.steps), ...r.notes, r.gap].filter(Boolean);
    const long = texts.filter((t) => t.length > LONG);
    if (long.length) {
      notes.push(`Note: "${r.title}" has ${long.length === 1 ? 'a step or note' : `${long.length} steps or notes`} over ${LONG} letters long, which may not fit
  on the Kobo's screen. Split ${long.length === 1 ? 'it' : 'them'} in two in recipes.js.`);
    }
  }
  const categories = [...new Set([...order, ...fresh])];
  for (const key of ['short', 'doodles']) {
    for (const chapter of Object.keys(book[key] || {})) {
      if (!categories.includes(chapter)) notes.push(`Note: book.json's "${key}" names "${chapter}", but no chapter is called that (renamed?).`);
    }
  }
  return { book, settings, all, recipes, categories, notes };
}
