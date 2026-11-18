// Loads recipes.js (plain JavaScript, so it can also be used by a web page): the master copy of
// the recipes.
//
//   loadRecipes()    -> { recipes, categories }  exactly as recipes.js has them
//   kitchenRecipes() -> { recipes, categories }  the same recipes in the kitchen's shape
//   normalize(r)     -> one recipe in the kitchen's shape
//   plain(s)         -> text with the unsure-reading marks written as "(?)"
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

export const root = new URL('..', import.meta.url);

export function loadRecipes() {
  const window = {};
  runInNewContext(readFileSync(new URL('recipes.js', root), 'utf8'), { window }, { filename: 'recipes.js' });
  if (!Array.isArray(window.RECIPES)) throw new Error('recipes.js should fill window.RECIPES with a list of recipes');
  return { recipes: window.RECIPES, categories: Array.isArray(window.CATEGORIES) ? window.CATEGORIES : [] };
}

// "word[?]" and "[illegible]" mark handwriting that couldn't be read for sure.
export const plain = (s) => String(s).replace(/\s?\[\?\]/g, ' (?)').replace(/\[illegible\]/g, '… (?)');

// The kitchen's shape: { slug, title, category, aka, sections: [{ heading, ingredients, steps }],
// notes, gap, hidden }, every text plain and trimmed, empty lines and sections dropped.
// A recipe with one section has no section name: the Kobo doesn't show one.
const str = (v) => (v == null ? '' : String(v));
const lines = (list) => (Array.isArray(list) ? list : []).map((x) => plain(str(x)).trim()).filter(Boolean);
export function normalize(r) {
  const sections = (Array.isArray(r.sections) ? r.sections : [])
    .map((s) => ({ heading: str(s && s.heading).trim(), ingredients: lines(s && s.ingredients), steps: lines(s && s.steps) }))
    .filter((s) => s.ingredients.length || s.steps.length);
  if (sections.length === 1) sections[0].heading = '';
  return {
    slug: str(r.slug).trim(),
    title: str(r.title).trim(),
    category: str(r.category).trim(),
    aka: plain(str(r.aka)).trim(),
    sections,
    notes: lines(r.notes),
    gap: plain(str(r.gap)).trim(),
    hidden: r.hidden === true,
  };
}

export function kitchenRecipes() {
  const { recipes, categories } = loadRecipes();
  return { recipes: recipes.map(normalize), categories };
}
