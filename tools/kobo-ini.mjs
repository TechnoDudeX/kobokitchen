// Edits Kobo's settings file (.kobo/Kobo/Kobo eReader.conf, an INI file) for
// tools/kobo-install.mjs.

// Change only the given keys in an INI file, keeping every other byte (comments, order, line
// endings) as it was. Works on latin1 text so any bytes round-trip unchanged.
export function editIni(text, edits) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const cr = eol === '\r\n' ? '\r' : '';
  const lines = text.split('\n');
  const done = new Set();
  const sectionEnd = {}; // section -> index of its last non-blank line
  let section = null;
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const s = raw.match(/^\s*\[([^\]]+)\]\s*\r?$/);
    if (s) { section = s[1]; sectionEnd[section] = i; continue; }
    if (section === null) continue;
    if (raw.trim()) sectionEnd[section] = i;
    const want = edits[section];
    if (!want) continue;
    const m = raw.match(/^(\s*)([^=;#\s][^=]*?)(\s*=[ \t]*)(.*?)(\r?)$/);
    if (m && Object.hasOwn(want, m[2])) {
      lines[i] = `${m[1]}${m[2]}${m[3]}${want[m[2]]}${m[5]}`;
      done.add(section + '/' + m[2]);
    }
  }
  // Keys that weren't there go at the end of their section; missing sections at the end of the file.
  const inserts = [];
  const appendix = [];
  for (const [sec, keys] of Object.entries(edits)) {
    const missing = Object.entries(keys).filter(([k]) => !done.has(sec + '/' + k)).map(([k, v]) => `${k}=${v}${cr}`);
    if (!missing.length) continue;
    if (sec in sectionEnd) inserts.push([sectionEnd[sec], missing]);
    else appendix.push(`[${sec}]${cr}`, ...missing);
  }
  inserts.sort((a, b) => b[0] - a[0]).forEach(([at, add]) => {
    if (at === lines.length - 1) { // the file's last line, with no line ending after it
      if (cr && !lines[at].endsWith('\r')) lines[at] += '\r';
      add[add.length - 1] = add[add.length - 1].replace(/\r$/, '');
    }
    lines.splice(at + 1, 0, ...add);
  });
  let out = lines.join('\n');
  if (appendix.length) {
    if (out && !out.endsWith('\n')) out += eol;
    if (out && !/(\r?\n){2}$/.test(out)) out += eol;
    out += appendix.join('\n') + '\n';
  }
  return out;
}
