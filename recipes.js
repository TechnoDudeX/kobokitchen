/* The recipes: the master copy. These six are made-up samples: replace them with your own.

   To add a recipe, copy one r(...) block and change it:

     r('Title', 'Chapter', [
       [heading or null, [ingredients...], [steps...]],   one block per part of the recipe
     ], { aka: '...', notes: ['...'], gap: '...' });       optional extras

   - The chapter is any name you like; book.json's "categoryOrder" sets the order of chapters.
   - A recipe in one part needs no heading (null). With several parts ("Cake", "Icing"), each
     gets its own heading on the Kobo.
   - Start an ingredient with its amount ("2 cups flour", "1/2 tsp salt") and the Kobo writes
     the amount in its own column.
   - Each step gets its own screen in cooking mode, so keep a step to a few sentences.
   - aka: another name for it. notes: tips, shown in a box after the steps. gap: a word about
     the recipe itself (what's missing from the card, say).
   - "word[?]" marks a word you couldn't read for sure in the original; the Kobo shows "(?)".
   - hidden: true keeps a recipe off the Kobo.
   Each recipe's name has to be different: it becomes its "slug" ("Lemon Drizzle Loaf" ->
   "lemon-drizzle-loaf"), which book.json's "hidden" uses too. */
window.RECIPES = [];
function r(title, category, sections, extra) {
  var o = {
    title: title, category: category,
    slug: title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''),
    sections: sections.map(function (s) { return { heading: s[0], ingredients: s[1] || [], steps: s[2] || [] }; }),
    notes: []
  };
  for (var k in (extra || {})) o[k] = extra[k];
  window.RECIPES.push(o);
}

/* ───────────── Soups & Stews ───────────── */

r('Sunday Tomato Soup', 'Soups & Stews', [
  [null, ['2 tbsp olive oil', '1 onion, chopped', '2 cloves garlic, sliced', '1 kg ripe tomatoes, quartered',
          '500 ml vegetable stock', '1 tsp sugar', 'salt and pepper', 'a handful of basil'],
    ['Warm the oil in a big pot and soften the onion for 8-10 minutes, without letting it brown.',
     'Add the garlic and cook for 1 more minute.',
     'Add the tomatoes, stock and sugar. Simmer with the lid on for 25 minutes.',
     'Take it off the heat, add the basil and blend until smooth.',
     'Taste, then season with salt and pepper.']]
], { notes: ['Lovely with cheese toasties.', 'It freezes well: leave a little room at the top of the box.'] });

r('Red Lentil Stew', 'Soups & Stews', [
  [null, ['1 tbsp oil', '1 onion, chopped', '2 carrots, diced', '1 tsp ground cumin', '1 tsp smoked paprika',
          '200 g red lentils, rinsed', '400 g tin chopped tomatoes', '1 litre stock', 'juice of half a lemon'],
    ['Soften the onion and carrots in the oil for 5 minutes.',
     'Stir in the cumin and paprika and cook for 1 minute.',
     'Add the lentils, tomatoes and stock. Simmer for 20-25 minutes, stirring now and then, until the lentils fall apart.',
     'Squeeze in the lemon juice and season to taste.']]
], { aka: 'Lentil pot' });

/* ───────────── Mains ───────────── */

r('Weeknight Fried Rice', 'Mains', [
  [null, ['2 tbsp oil', '2 eggs, beaten', '3 spring onions, sliced', '1 cup frozen peas',
          '3 cups cooked rice, cold', '2 tbsp soy sauce', '1 tsp sesame oil'],
    ['Heat 1 tbsp oil in a wok. Scramble the eggs, then tip them onto a plate.',
     'Add the rest of the oil and fry the spring onions and peas for 2 minutes.',
     'Add the rice and fry over a high heat, pressing out any lumps, until it is hot through.',
     'Stir in the soy sauce, sesame oil and the eggs.']]
], { notes: ['Day-old rice works best: freshly cooked rice goes mushy.'] });

r('Sheet Pan Chicken', 'Mains', [
  [null, ['8 chicken thighs', '600 g baby potatoes, halved', '1 red onion, in wedges', '1 lemon, in wedges',
          '3 tbsp olive oil', '1 tsp dried oregano', 'salt and pepper'],
    ['Heat the oven to 200°C (400°F).',
     'Toss everything together on a big baking tray, with the chicken skin side up.',
     'Roast for 40-45 minutes, until the chicken is golden and cooked through.',
     'Squeeze the roasted lemon over everything before serving.']]
], { gap: 'The card says "pinch of chilli[?]" in the corner: try it if you like.' });

/* ───────────── Baking ───────────── */

r('Lemon Drizzle Loaf', 'Baking', [
  ['Cake', ['225 g butter, soft', '225 g caster sugar', '4 eggs', 'zest of 1 lemon', '225 g self-raising flour'],
    ['Heat the oven to 180°C (350°F) and line a loaf tin.',
     'Beat the butter and sugar until pale and fluffy.',
     'Beat in the eggs one at a time, then the lemon zest.',
     'Fold in the flour, spoon it into the tin and bake for 45-50 minutes.']],
  ['Drizzle', ['juice of 1½ lemons', '85 g caster sugar'],
    ['Mix the lemon juice and sugar.',
     'While the cake is still warm, poke it all over with a skewer and pour the drizzle over it.',
     'Let it cool in the tin.']]
], { notes: ['A skewer pushed into the middle should come out clean when it is done.'] });

/* ───────────── Snacks ───────────── */

r('Banana Oat Cookies', 'Snacks', [
  [null, ['2 ripe bananas', '1 1/2 cups rolled oats', '1/3 cup chocolate chips', '1/2 tsp cinnamon', 'pinch of salt'],
    ['Heat the oven to 180°C (350°F) and line a baking tray.',
     'Mash the bananas, then stir in everything else.',
     'Drop spoonfuls onto the tray and flatten them a little.',
     'Bake for 12-15 minutes, until golden at the edges.']]
]);
