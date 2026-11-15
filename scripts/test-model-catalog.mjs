// node scripts/test-model-catalog.mjs — the Models library's data rules
// (src/modelCatalog.ts): filters, sort orders, sizes and the measured speed.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";
const source = await readFile(new URL("../src/modelCatalog.ts", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const { SPEECH_MODELS, POLISH_RATINGS, filterAndSort, formatBytes, measuredSpeed, speechInfo, accuracyScore, speedScore, isMeasured } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`);

const row = (id, extra = {}) => ({ id, kind: "speech", name: id, language: "multi", bytes: 1, speed: 3, accuracy: 3, rank: 5, installed: false, inUse: false, favorite: false, location: "local", searchText: id, ...extra });
const all = { query: "", kind: "all", language: "all", downloadedOnly: false, localOnly: false };
const ids = (rows) => rows.map((r) => r.id);

// Every speech model the app ships has library data, one recommended default.
assert.deepEqual(SPEECH_MODELS.filter((m) => m.recommended).map((m) => m.id), ["parakeet-tdt-0.6b-v3"]);
for (const m of SPEECH_MODELS) {
  assert.ok(m.speed >= 1 && m.speed <= 5 && m.accuracy >= 1 && m.accuracy <= 5, m.id);
  assert.ok(m.bytes > 0, m.id);
}
for (const id of ["speakoflow-mini", "qwen3.5-0.8b", "qwen3.5-2b", "qwen3.5-4b"]) assert.ok(POLISH_RATINGS[id], id);
assert.equal(speechInfo("parakeet-tdt-0.6b-v2").language, "en");

// Ratings follow the benchmark scale (apps/macos/docs/model-benchmarks.md).
assert.deepEqual([2.07, 2.75, 3.11, 4.4, 6.22, 9].map(accuracyScore), [5, 4, 4, 3, 2, 1]);
assert.deepEqual([129, 100, 57, 16, 5.1, 3.3].map(speedScore), [5, 5, 4, 3, 2, 1]);
assert.deepEqual([speechInfo("large-v3").speed, speechInfo("large-v3").accuracy], [1, 5]);
assert.equal(isMeasured(speechInfo("parakeet-tdt-0.6b-v3")), true);
assert.equal(isMeasured(speechInfo("parakeet-tdt-0.6b-v2")), false, "v2 has no figures yet: its ratings are estimates");
assert.equal(speechInfo("unknown-size").name, "Whisper unknown-size");

// Default order: in use, then favourites, then rank.
const rows = [row("a", { rank: 1 }), row("b", { rank: 2, favorite: true }), row("c", { rank: 3, inUse: true }), row("d", { rank: 0 })];
assert.deepEqual(ids(filterAndSort(rows, all, "recommended")), ["c", "b", "d", "a"]);

// Sorts.
const sized = [row("big", { bytes: 3e9, speed: 1, accuracy: 5 }), row("small", { bytes: 1e8, speed: 5, accuracy: 1, name: "Alpha" })];
assert.deepEqual(ids(filterAndSort(sized, all, "size")), ["small", "big"]);
assert.deepEqual(ids(filterAndSort(sized, all, "speed")), ["small", "big"]);
assert.deepEqual(ids(filterAndSort(sized, all, "accuracy")), ["big", "small"]);
assert.deepEqual(ids(filterAndSort(sized, all, "name")), ["small", "big"]);

// Filters: kind, language, downloaded (remote rows count as available), local, query.
const mixed = [
  row("speech-en", { language: "en", installed: true }),
  row("polish", { kind: "polish" }),
  row("host", { location: "host", installed: false }),
  row("query-hit", { searchText: "Whisper Large v3 turbo" }),
];
assert.deepEqual(ids(filterAndSort(mixed, { ...all, kind: "polish" }, "name")), ["polish"]);
assert.deepEqual(ids(filterAndSort(mixed, { ...all, language: "en" }, "name")), ["speech-en"]);
assert.deepEqual(ids(filterAndSort(mixed, { ...all, downloadedOnly: true }, "name")), ["host", "speech-en"]);
assert.ok(!ids(filterAndSort(mixed, { ...all, localOnly: true }, "name")).includes("host"));
assert.deepEqual(ids(filterAndSort(mixed, { ...all, query: "TURBO" }, "name")), ["query-hit"]);

// Sizes and measured speed.
assert.equal(formatBytes(2.5e9), "2.5 GB");
assert.equal(formatBytes(148e6), "148 MB");
assert.equal(formatBytes(0), "—");
const m = "parakeet-tdt-0.6b-v3";
assert.equal(measuredSpeed([], m), null);
assert.equal(measuredSpeed([{ model: m, durationSeconds: 10, timings: { speechModelMs: 0 } }, { model: m, durationSeconds: 5, timings: null }], m), null);
assert.equal(measuredSpeed([{ model: m, durationSeconds: 10, timings: { speechModelMs: 1000 } }, { model: m, durationSeconds: 10, timings: { speechModelMs: 500 } }, { model: m, durationSeconds: 3, timings: { speechModelMs: 1000 } }], m), 10);
// Only that model's own dictations count: another model's or an unlabelled one never does.
assert.equal(measuredSpeed([{ model: "tiny", durationSeconds: 10, timings: { speechModelMs: 100 } }, { durationSeconds: 10, timings: { speechModelMs: 100 } }], m), null);
console.log("model catalog: ok");
