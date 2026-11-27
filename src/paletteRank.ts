// Ranking and labels for the Ctrl+K palette (src/palette.ts), the same rules
// as the Mac app's (FairspokenCore PaletteSearch, DictationText, AppMonogram).
// Pure functions only, so scripts/test-palette-rank.mjs can run them in Node.
//
// Every word typed has to be found somewhere in an entry; a whole word beats
// the start of a word, which beats the middle of one. Matching ignores case
// and accents ("aoife" finds "Aoife", "cafe" finds "café"). Ties keep the
// order given (for dictations, newest first).

/** One searchable entry: its title (counted in full) and other fields
 * (counted at a discount, e.g. the app's name or keywords). */
export interface Fields {
  title: string;
  other?: string[];
}

const WHOLE_WORD = 100;
const WORD_START = 70;
const INSIDE = 35;
/** Letters in order inside one word ("trnscr" → "Transcription"): commands only. */
const SCATTERED = 12;

const MARKS = /\p{M}+/gu;
const WORD_CHAR = /[\p{L}\p{N}]/u;

interface Folded {
  text: string;
  /** For each UTF-16 unit of `text`, where it came from in the original. */
  origin: number[];
}

/** Lower case without accents, keeping where each folded unit came from. */
function foldMapped(text: string): Folded {
  let out = "";
  const origin: number[] = [];
  let index = 0;
  for (const char of text) {
    const folded = char.normalize("NFD").replace(MARKS, "").toLowerCase();
    out += folded;
    for (let i = 0; i < folded.length; i++) origin.push(index);
    index += char.length;
  }
  origin.push(index);
  return { text: out, origin };
}

export function fold(text: string): string {
  return foldMapped(text).text;
}

export function tokenize(query: string): string[] {
  return fold(query).split(/\s+/u).filter(Boolean);
}

function isWordChar(char: string | undefined): boolean {
  return char !== undefined && WORD_CHAR.test(char);
}

/** The token's letters in order within one word of `text`, from that word's start. */
function isScattered(token: string, text: string): boolean {
  for (const word of text.split(/[^\p{L}\p{N}]+/u)) {
    if (!word || word[0] !== token[0]) continue;
    let at = 0;
    let found = true;
    for (const char of token) {
      const hit = word.indexOf(char, at);
      if (hit < 0) { found = false; break; }
      at = hit + char.length;
    }
    if (found) return true;
  }
  return false;
}

function match(token: string, text: string, allowScattered: boolean): number | null {
  let best: number | null = null;
  let from = 0;
  for (;;) {
    const at = text.indexOf(token, from);
    if (at < 0) break;
    const end = at + token.length;
    const startsWord = at === 0 || !isWordChar(text[at - 1]);
    const endsWord = end === text.length || !isWordChar(text[end]);
    const value = startsWord ? (endsWord ? WHOLE_WORD : WORD_START) : INSIDE;
    best = Math.max(best ?? 0, value);
    if (value === WHOLE_WORD) break;
    from = at + 1;
  }
  if (best === null && allowScattered && [...token].length >= 3 && isScattered(token, text)) best = SCATTERED;
  return best;
}

/** The entry's score for `query`, or null when some word of the query isn't
 * in it. An empty query matches everything with 0. */
export function score(query: string, fields: Fields, allowScattered = false): number | null {
  const tokens = tokenize(query);
  if (tokens.length === 0) return 0;
  const title = fold(fields.title);
  const others = (fields.other ?? []).map(fold);
  let total = 0;
  for (const token of tokens) {
    const inTitle = match(token, title, allowScattered);
    let inOthers: number | null = null;
    for (const other of others) {
      const value = match(token, other, allowScattered);
      if (value !== null) inOthers = Math.max(inOthers ?? 0, value);
    }
    if (inOthers !== null) inOthers = Math.trunc((inOthers * 6) / 10);
    const best = Math.max(inTitle ?? -1, inOthers ?? -1);
    if (best < 0) return null;
    total += best;
  }
  // The whole query as typed, in the title: a phrase beats the same words apart.
  if (tokens.length > 1 && title.includes(tokens.join(" "))) total += 40;
  return total;
}

export interface RankOptions {
  limit?: number;
  allowScattered?: boolean;
}

/** `items` that match, best first; equal scores keep their order. */
export function rank<T>(items: readonly T[], query: string, fields: (item: T) => Fields, options: RankOptions = {}): T[] {
  const scored: Array<{ value: number; index: number; item: T }> = [];
  items.forEach((item, index) => {
    const value = score(query, fields(item), options.allowScattered ?? false);
    if (value !== null) scored.push({ value, index, item });
  });
  scored.sort((a, b) => (a.value !== b.value ? b.value - a.value : a.index - b.index));
  const sorted = scored.map((entry) => entry.item);
  return options.limit === undefined ? sorted : sorted.slice(0, options.limit);
}

/** Where the query's words are in `text` (the first of each), as [start, end)
 * offsets into `text`, in order, to underline them. */
export function matchRanges(query: string, text: string): Array<[number, number]> {
  const folded = foldMapped(text);
  const ranges: Array<[number, number]> = [];
  for (const token of tokenize(query)) {
    const at = folded.text.indexOf(token);
    if (at < 0) continue;
    ranges.push([folded.origin[at], folded.origin[at + token.length]]);
  }
  ranges.sort((a, b) => a[0] - b[0]);
  // Overlapping words ("quote quo") underline once.
  const merged: Array<[number, number]> = [];
  for (const range of ranges) {
    const last = merged[merged.length - 1];
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1]);
    else merged.push([range[0], range[1]]);
  }
  return merged;
}

// ── Labels ──────────────────────────────────────────────────────────────

/** A dictation's title: its first line, unless that is only a short
 * greeting ("Hi Aoife,"), when the next line says more. */
export function dictationTitle(text: string): string {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  if (lines.length === 0) return "Empty dictation";
  let line = lines[0];
  if (lines.length > 1 && line.endsWith(",") && line.split(" ").filter(Boolean).length <= 4) line = lines[1];
  return line;
}

/** "now", "14m", "3h", "4d", "3w". */
export function ageLabel(createdAt: number, now: number): string {
  const s = Math.max(0, (now - createdAt) / 1000);
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86_400) return `${Math.floor(s / 3600)}h`;
  if (s < 86_400 * 14) return `${Math.floor(s / 86_400)}d`;
  return `${Math.floor(s / (86_400 * 7))}w`;
}

/** Two letters for an app: the initials of a two-word name ("Google Docs" →
 * GD), else its first two letters ("Slack" → SL). */
export function monogramLetters(name: string): string {
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (words.length >= 2) return ([...words[0]][0] + [...words[1]][0]).toUpperCase();
  return [...name].filter((char) => WORD_CHAR.test(char)).slice(0, 2).join("").toUpperCase();
}

/** Apps the Mac pins to a hue, by name here (the desktop app knows names, not bundle ids). */
const KNOWN_HUES: Record<string, number> = { mail: 0, slack: 1, xcode: 2, messages: 3, notes: 4 };
export const MONOGRAM_HUES = 5;

/** Which of the five monogram hues (`--bark-mono-0..4`) an app gets: stable
 * for a name across launches, the same hash as the Mac's. */
export function monogramHue(name: string): number {
  const known = KNOWN_HUES[name.toLowerCase()];
  if (known !== undefined) return known;
  let hash = 0;
  for (const char of name) hash = (Math.imul(hash, 31) + (char.codePointAt(0) ?? 0)) & 0xffff;
  return hash % MONOGRAM_HUES;
}
