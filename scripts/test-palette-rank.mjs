// node scripts/test-palette-rank.mjs — the Ctrl+K palette's search ranking
// and labels (src/paletteRank.ts), the same cases as the Mac app's
// PaletteSearch tests so both apps find the same things.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";
const source = await readFile(new URL("../src/paletteRank.ts", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const { rank, matchRanges, dictationTitle, ageLabel, monogramLetters, monogramHue } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`);

const titles = (items, query, scattered = false) =>
  rank(items, query, (item) => ({ title: item.title, other: [item.app] }), { allowScattered: scattered }).map((item) => item.title);

const dictations = [
  { title: "Could you send the revised quote by Friday?", app: "Mail" },
  { title: "Kitchen quote: worktop, two wall units", app: "Notes" },
  { title: "running ten minutes late, start without me", app: "Slack" },
  { title: "Quotes from the meeting", app: "Mail" },
  { title: "Thanks Aoife, see you at the café", app: "Messages" },
];

// An empty query keeps the order.
assert.deepEqual(titles(dictations, ""), dictations.map((d) => d.title));
assert.deepEqual(titles(dictations, "   "), dictations.map((d) => d.title));

// Whole words beat word starts, and ties keep recency.
assert.deepEqual(titles(dictations, "quote"), [
  "Could you send the revised quote by Friday?",
  "Kitchen quote: worktop, two wall units",
  "Quotes from the meeting",
]);

// Every word must match somewhere.
assert.deepEqual(titles(dictations, "quote mail"), ["Could you send the revised quote by Friday?", "Quotes from the meeting"]);
assert.deepEqual(titles(dictations, "quote slack"), []);

// App names match but count for less.
assert.deepEqual(titles([{ title: "Slack status update", app: "Mail" }, { title: "On my way", app: "Slack" }], "slack"),
  ["Slack status update", "On my way"]);

// Case and accents are ignored.
assert.deepEqual(titles(dictations, "AOIFE"), ["Thanks Aoife, see you at the café"]);
assert.deepEqual(titles(dictations, "cafe"), ["Thanks Aoife, see you at the café"]);

// A phrase beats the same words apart.
assert.equal(titles([{ title: "ten past the hour, minutes later", app: "Notes" }, { title: "running ten minutes late", app: "Slack" }], "ten minutes")[0],
  "running ten minutes late");

// Scattered letters only when asked, and not for short queries.
const commands = [{ title: "Transcription", app: "Settings" }, { title: "Vocabulary", app: "Settings" }];
assert.deepEqual(titles(commands, "trnscr"), []);
assert.deepEqual(titles(commands, "trnscr", true), ["Transcription"]);
assert.deepEqual(titles(commands, "vb", true), []);

// The limit caps the result.
assert.equal(rank(dictations, "", (d) => ({ title: d.title }), { limit: 2 }).length, 2);

// Match ranges find each word, in order, in the original text.
{
  const text = "Could you send the revised quote by Friday?";
  assert.deepEqual(matchRanges("friday QUOTE", text).map(([a, b]) => text.slice(a, b)), ["quote", "Friday"]);
  const accented = "Thanks Aoife, see you at the café";
  assert.deepEqual(matchRanges("cafe", accented).map(([a, b]) => accented.slice(a, b)), ["café"]);
  // A decomposed accent still underlines the whole letter.
  const decomposed = "café au lait";
  assert.deepEqual(matchRanges("cafe", decomposed).map(([a, b]) => decomposed.slice(a, b)), ["café"]);
  assert.deepEqual(matchRanges("fetchquote quote", "Rename fetchQuote to loadQuote"), [[7, 17]]);
}

// A dictation's title skips a short greeting.
assert.equal(dictationTitle("Hi Aoife,\n\nSo could you send the quote?\n\nThanks,\nSam"), "So could you send the quote?");
assert.equal(dictationTitle("Running late, sorry, see you there, bye now,\nsecond"), "Running late, sorry, see you there, bye now,");
assert.equal(dictationTitle("  \n"), "Empty dictation");
assert.equal(dictationTitle("One line"), "One line");

// Ages.
{
  const now = 1_000_000_000_000;
  assert.equal(ageLabel(now - 30_000, now), "now");
  assert.equal(ageLabel(now - 14 * 60_000, now), "14m");
  assert.equal(ageLabel(now - 3 * 3_600_000, now), "3h");
  assert.equal(ageLabel(now - 4 * 86_400_000, now), "4d");
  assert.equal(ageLabel(now - 21 * 86_400_000, now), "3w");
  assert.equal(ageLabel(now + 5_000, now), "now");
}

// Monograms: two-word initials, else the first two letters; stable hues.
assert.equal(monogramLetters("Google Docs"), "GD");
assert.equal(monogramLetters("Slack"), "SL");
assert.equal(monogramLetters("Visual Studio Code"), "VS");
assert.equal(monogramLetters("x"), "X");
assert.deepEqual(["Mail", "Slack", "Xcode", "Messages", "Notes"].map(monogramHue), [0, 1, 2, 3, 4]);
assert.equal(monogramHue("Outlook"), monogramHue("Outlook"));
for (const name of ["Outlook", "WhatsApp", "Notepad", "Google Docs", ""]) {
  const hue = monogramHue(name);
  assert.ok(Number.isInteger(hue) && hue >= 0 && hue < 5, `${name} → ${hue}`);
}
// The Mac's hash: ((h * 31 + scalar) & 0xFFFF), mod 5.
{
  let h = 0;
  for (const c of "Outlook") h = (h * 31 + c.codePointAt(0)) & 0xffff;
  assert.equal(monogramHue("Outlook"), h % 5);
}

console.log("palette rank: ok");
