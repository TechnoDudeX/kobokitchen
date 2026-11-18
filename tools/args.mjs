// Strict command-line options for the kitchen tools: a misspelt option, a stray word or a
// missing value stops the tool before it touches anything, instead of being quietly ignored
// (a typo in --dry-run must never turn into a real run).
//
//   const opts = options({ 'dry-run': { type: 'boolean' }, out: { type: 'string' } }, usage)
//
// --help / -h prints `usage` and exits. Values can be given as "--out FILE" or "--out=FILE".
import { parseArgs } from 'node:util';

export function options(spec, usage) {
  let values;
  try {
    ({ values } = parseArgs({
      args: process.argv.slice(2),
      options: { help: { type: 'boolean', short: 'h' }, ...spec },
      strict: true,
      allowPositionals: false,
    }));
  } catch (e) {
    console.error(`${e.message}\n\n${usage}`);
    process.exit(2);
  }
  if (values.help) {
    console.log(usage);
    process.exit(0);
  }
  for (const [name, value] of Object.entries(values)) {
    if (typeof value === 'string' && !value.trim()) {
      console.error(`--${name} needs a value.\n\n${usage}`);
      process.exit(2);
    }
  }
  return values;
}
