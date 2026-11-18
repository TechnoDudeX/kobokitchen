// Small pieces the kitchen tools share: each chapter's doodle, its short name, an ingredient's
// amount, and dates.
//
//   LOOSE                            the last chapter's name, for recipes with no category
//   DOODLES                          the doodles tools/make-art.mjs draws (art/<name>.png)
//   chapterDoodles(names, chosen)    -> Map(chapter name -> doodle name)
//   shortName(chapter, short)        -> the chapter's name on its tile
//   splitAmount(line)                -> [amount, rest]: "300 g flour" -> ["300 g", "flour"]
//   isPng(buffer)                    -> is it a whole PNG?
//   ymd(date), noon(date)            -> "2026-11-18"; that day at 12:00 (local time)

export const LOOSE = 'Everything else';

// The chapter doodles, in the order a chapter with no match gets them. (The heart, the wave and
// the two tiles are drawn too, for other places.)
export const DOODLES = ['pot', 'flame', 'bowl', 'bread', 'cake', 'cookie', 'whisk', 'samosa'];

// Words in a chapter's name that suggest its doodle.
const HINTS = [
  ['pot', /curr|stew|dal\b|dhal|rice|biryani|casserole|chil[il]|braise|one.?pot|mains?\b|dinner/],
  ['flame', /grill|bbq|barbec|marinade|roast|meat|chicken|fish|kebab/],
  ['bowl', /soup|noodle|pasta|salad|bowl|ramen|broth/],
  ['bread', /bread|bun|roll|side|toast|sandwich|breakfast|brunch|flatbread|naan|roti/],
  ['cake', /cake|cupcake|dessert|pudding|\bpies?\b|tart|bak(e|ing)/],
  ['cookie', /cookie|biscuit|brownie|sweet|treat|cand(y|ies)|\bbars?\b|fudge/],
  ['whisk', /icing|frosting|topping|sauce|dressing|\bdips?\b|glaze|cream|drink|chutney|jam/],
  ['samosa', /samosa|pakora|snack|starter|appeti[sz]er|savou?ry|party/],
];

// Each chapter's doodle: the one book.json's "doodles" chooses for it, else one its name
// suggests that no other chapter has yet, else the next one no chapter has. Once all of them
// are taken, and for the loose chapter, the heart.
export function chapterDoodles(names, chosen = {}) {
  const out = new Map();
  const used = new Set();
  for (const n of names) {
    if (chosen && typeof chosen[n] === 'string' && chosen[n]) { out.set(n, chosen[n]); used.add(chosen[n]); }
  }
  for (const n of names) {
    if (out.has(n) || n === LOOSE) continue;
    const lower = String(n).toLowerCase();
    const hint = HINTS.find(([icon, re]) => !used.has(icon) && re.test(lower));
    if (hint) { out.set(n, hint[0]); used.add(hint[0]); }
  }
  for (const n of names) {
    if (out.has(n)) continue;
    const free = n === LOOSE ? null : DOODLES.find((i) => !used.has(i));
    if (free) used.add(free);
    out.set(n, free || 'heart');
  }
  return out;
}

// A chapter's short name for its tile: book.json's "short", or its name up to the first ",",
// "&" or "/".
export const shortName = (chapter, short = {}) => (short && short[chapter]) || String(chapter).split(/[,&/]/)[0].trim();

const pad = (n, w) => String(n).padStart(w, '0');
// A date as YYYY-MM-DD from its local calendar day (not UTC, which can be the day before or after).
export const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1, 2)}-${pad(d.getDate(), 2)}`;
export const noon = (d = new Date()) => new Date(d.getFullYear(), d.getMonth(), d.getDate(), 12, 0, 0);

// An ingredient's amount, split off so it can be written in the handwriting: "300 gms",
// "1/2 cup", "6-7", "113.5g". Lines without an amount ("salt", "optional: cinnamon") stay whole.
const UNIT = 'tsps?|tbsps?|tablespoons?|teaspoons?|cups?|c|g|gms?|grams?|kgs?|ml|l|litres?|liters?|oz|lbs?|pounds?|pinch(?:es)?|cloves?|pieces?|pcs|packets?|cans?|tins?|sticks?|slices?|bunch(?:es)?|handfuls?|drops?|inch(?:es)?|cm|dash(?:es)?|scoops?|sprigs?|stalks?|blocks?|bags?|jars?|cubes?';
const AMOUNT = new RegExp(`^((?:~\\s*|about\\s+)?(?:\\d+(?:[.,]\\d+)?(?:\\s*(?:-|–|to)\\s*\\d+(?:[.,]\\d+)?)?(?:\\s+\\d+\\/\\d+)?|\\d+\\/\\d+|[½¼¾⅓⅔⅛])(?:\\s*(?:${UNIT})\\b\\.?)?)\\s+(\\S.*)$`, 'i');
export function splitAmount(line) {
  const m = String(line).match(AMOUNT);
  return m ? [m[1], m[2]] : ['', String(line)];
}

// A whole PNG: the signature, a header with a real width and height, and the end chunk (IEND)
// as the last 12 bytes. An empty, cut-off or non-PNG file is treated as missing.
export function isPng(data) {
  return !!data && data.length >= 57 && data.readUInt32BE(0) === 0x89504e47 && data.readUInt32BE(4) === 0x0d0a1a0a &&
    data.toString('latin1', 12, 16) === 'IHDR' && data.readUInt32BE(16) > 0 && data.readUInt32BE(20) > 0 &&
    data.toString('latin1', data.length - 8, data.length - 4) === 'IEND';
}
