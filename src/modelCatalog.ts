// What the app knows about each model it can download, for the Models
// library and the onboarding model step. Pure data and helpers: no DOM, no
// Tauri, so scripts/test-model-catalog.mjs can check it.
//
// Speed and accuracy are 1–5 ratings. For the speech models they come from
// the reference measurements in apps/macos/docs/model-benchmarks.md (word
// error rate and real-time factor on 20 English LibriSpeech clips, through
// the Mac app's engines on an M4), on the same scale the Mac app's library
// uses, so both apps agree. This app runs Whisper on a different engine, so
// they are a guide to how the models compare, not a promise of speed here. Where a model has no measurement (Parakeet v2, the polish
// models) the rating is an estimate and `measured` is false; the library
// marks those. The model in use also shows its speed measured on this
// computer, from the dictation history (measuredSpeed below).

export type ModelKind = "speech" | "polish";

export interface ModelInfo {
  id: string;
  kind: ModelKind;
  name: string;
  /** The short line under the name. */
  summary: string;
  publisher: string;
  /** Approximate download size in bytes (polish models report their own). */
  bytes: number;
  /** "en" or "multi". */
  language: "en" | "multi";
  languages: string;
  speed: number;
  accuracy: number;
  /** Benchmark figures behind the ratings, when there are any. */
  wer?: number;
  rtfx?: number;
  recommended?: boolean;
  isNew?: boolean;
  /** Order in the default sort: lower first. */
  rank: number;
}

const GB = 1e9;
const MB = 1e6;

/** The Mac app's ScoreScale: accuracy from word error rate (%), speed from real-time factor. */
export function accuracyScore(wer: number): number {
  return wer < 2.75 ? 5 : wer < 3.5 ? 4 : wer < 5 ? 3 : wer < 8 ? 2 : 1;
}
export function speedScore(rtfx: number): number {
  return rtfx >= 100 ? 5 : rtfx >= 40 ? 4 : rtfx >= 15 ? 3 : rtfx >= 5 ? 2 : 1;
}
type Speech = Omit<ModelInfo, "speed" | "accuracy" | "kind"> & { speed?: number; accuracy?: number };
function speech(model: Speech): ModelInfo {
  return {
    ...model,
    kind: "speech",
    speed: model.rtfx !== undefined ? speedScore(model.rtfx) : model.speed ?? 3,
    accuracy: model.wer !== undefined ? accuracyScore(model.wer) : model.accuracy ?? 3,
  };
}
export const isMeasured = (model: Pick<ModelInfo, "wer" | "rtfx">): boolean => model.wer !== undefined && model.rtfx !== undefined;

export const SPEECH_MODELS: ModelInfo[] = [
  speech({ id: "parakeet-tdt-0.6b-v3", name: "Parakeet v3", summary: "Fast and accurate, the default", publisher: "NVIDIA", bytes: 2.5 * GB, language: "multi", languages: "25 European languages", wer: 2.07, rtfx: 129, recommended: true, rank: 0 }),
  speech({ id: "parakeet-ultra", name: "Parakeet Ultra", summary: "A post-trained v3", publisher: "Moondream", bytes: 2.6 * GB, language: "multi", languages: "25 European languages", wer: 2.33, rtfx: 120, isNew: true, rank: 1 }),
  speech({ id: "parakeet-tdt-0.6b-v2", name: "Parakeet v2", summary: "The earlier release, tuned for English", publisher: "NVIDIA", bytes: 2.51 * GB, language: "en", languages: "English", speed: 5, accuracy: 4, rank: 2 }),
  speech({ id: "large-v3-turbo", name: "Whisper Large v3 Turbo", summary: "The quickest of the large Whispers", publisher: "OpenAI", bytes: 1.62 * GB, language: "multi", languages: "99 languages", wer: 3.11, rtfx: 8, rank: 3 }),
  speech({ id: "large-v3", name: "Whisper Large v3", summary: "The newest large Whisper", publisher: "OpenAI", bytes: 3.1 * GB, language: "multi", languages: "99 languages", wer: 2.59, rtfx: 3.5, rank: 4 }),
  speech({ id: "large-v2", name: "Whisper Large v2", summary: "The previous large Whisper", publisher: "OpenAI", bytes: 3.09 * GB, language: "multi", languages: "99 languages", wer: 2.33, rtfx: 3.3, rank: 5 }),
  speech({ id: "medium", name: "Whisper Medium", summary: "Accurate, but slow", publisher: "OpenAI", bytes: 1.53 * GB, language: "multi", languages: "99 languages", wer: 2.33, rtfx: 5.1, rank: 6 }),
  speech({ id: "small", name: "Whisper Small", summary: "A lighter download", publisher: "OpenAI", bytes: 488 * MB, language: "multi", languages: "99 languages", wer: 4.4, rtfx: 16, rank: 7 }),
  speech({ id: "base", name: "Whisper Base", summary: "Small download, rougher text", publisher: "OpenAI", bytes: 148 * MB, language: "multi", languages: "99 languages", wer: 6.22, rtfx: 57, rank: 8 }),
  speech({ id: "tiny", name: "Whisper Tiny", summary: "Smallest download, for slow machines", publisher: "OpenAI", bytes: 78 * MB, language: "multi", languages: "99 languages", wer: 7.77, rtfx: 105, rank: 9 }),
];

/** Ratings for the polish models; their names, sizes and summaries come from the backend catalog. */
export const POLISH_RATINGS: Record<string, Pick<ModelInfo, "speed" | "accuracy" | "language" | "languages" | "rank"> & { recommended?: boolean; isNew?: boolean }> = {
  "speakoflow-mini": { speed: 4, accuracy: 4, language: "en", languages: "English", rank: 10, isNew: true },
  "qwen3.5-2b": { speed: 4, accuracy: 3, language: "multi", languages: "Many languages", rank: 11, recommended: true },
  "qwen3.5-0.8b": { speed: 5, accuracy: 2, language: "multi", languages: "Many languages", rank: 12 },
  "qwen3.5-4b": { speed: 2, accuracy: 5, language: "multi", languages: "Many languages", rank: 13 },
};

export function speechInfo(id: string): ModelInfo {
  return SPEECH_MODELS.find((model) => model.id === id)
    ?? { id, kind: "speech", name: `Whisper ${id}`, summary: "Speech recognition", publisher: "OpenAI", bytes: 0, language: "multi", languages: "Many languages", speed: 3, accuracy: 3, rank: 50 };
}

export function formatBytes(bytes: number): string {
  if (!bytes) return "—";
  return bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.round(bytes / 1e6)} MB`;
}

export type SortKey = "recommended" | "name" | "size" | "speed" | "accuracy";

export interface LibraryRow {
  id: string;
  kind: ModelKind;
  name: string;
  language: "en" | "multi";
  bytes: number;
  speed: number;
  accuracy: number;
  rank: number;
  installed: boolean;
  inUse: boolean;
  favorite: boolean;
  location: "local" | "host" | "cloud";
  searchText: string;
}

export interface LibraryFilter {
  query: string;
  kind: "all" | ModelKind;
  language: "all" | "en" | "multi";
  downloadedOnly: boolean;
  localOnly: boolean;
}

/** The rows a filter keeps, sorted. Favourites and the models in use lead the default sort. */
export function filterAndSort<T extends LibraryRow>(rows: T[], filter: LibraryFilter, sort: SortKey): T[] {
  const needle = filter.query.trim().toLowerCase();
  const kept = rows.filter((row) =>
    (filter.kind === "all" || row.kind === filter.kind)
    && (filter.language === "all" || row.language === filter.language)
    && (!filter.downloadedOnly || row.installed || row.location !== "local")
    && (!filter.localOnly || row.location === "local")
    && (!needle || row.searchText.toLowerCase().includes(needle)));
  const by: Record<SortKey, (a: T, b: T) => number> = {
    recommended: (a, b) => Number(b.inUse) - Number(a.inUse) || Number(b.favorite) - Number(a.favorite) || a.rank - b.rank,
    name: (a, b) => a.name.localeCompare(b.name),
    size: (a, b) => a.bytes - b.bytes || a.rank - b.rank,
    speed: (a, b) => b.speed - a.speed || a.rank - b.rank,
    accuracy: (a, b) => b.accuracy - a.accuracy || a.rank - b.rank,
  };
  return [...kept].sort(by[sort]);
}

/** A model's speed on this machine, from recent dictations it transcribed: seconds of speech per second of compute. */
export function measuredSpeed(history: { durationSeconds: number; model?: string | null; timings?: { speechModelMs: number } | null }[], model: string): number | null {
  const timed = history.filter((item) => item.model === model && item.timings && item.timings.speechModelMs > 0 && item.durationSeconds > 0);
  if (timed.length === 0) return null;
  const ratios = timed.map((item) => (item.durationSeconds * 1000) / item.timings!.speechModelMs).sort((a, b) => a - b);
  const mid = Math.floor(ratios.length / 2);
  return ratios.length % 2 ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2;
}
