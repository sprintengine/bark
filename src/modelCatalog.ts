// What the app knows about each model it can download, for the Models
// library and the onboarding model step. Pure data and helpers: no DOM, no
// Tauri, so scripts/test-model-catalog.mjs can check it.
//
// Speed and accuracy are 1–5 ratings. They are ESTIMATES from the models'
// published benchmarks and their size, relative to each other within a kind;
// the library says so. The one measured number, the model in use's speed on
// this machine, comes from the dictation history (measuredSpeed below).

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
  recommended?: boolean;
  isNew?: boolean;
  /** Order in the default sort: lower first. */
  rank: number;
}

const GB = 1e9;
const MB = 1e6;

export const SPEECH_MODELS: ModelInfo[] = [
  { id: "parakeet-tdt-0.6b-v3", kind: "speech", name: "Parakeet v3", summary: "Fast and accurate, the default", publisher: "NVIDIA", bytes: 2.5 * GB, language: "multi", languages: "25 European languages", speed: 5, accuracy: 4, recommended: true, rank: 0 },
  { id: "parakeet-ultra", kind: "speech", name: "Parakeet Ultra", summary: "Post-trained v3 with lower error rates", publisher: "Moondream", bytes: 2.6 * GB, language: "multi", languages: "25 European languages", speed: 5, accuracy: 5, isNew: true, rank: 1 },
  { id: "parakeet-tdt-0.6b-v2", kind: "speech", name: "Parakeet v2", summary: "The earlier release, tuned for English", publisher: "NVIDIA", bytes: 2.51 * GB, language: "en", languages: "English", speed: 5, accuracy: 4, rank: 2 },
  { id: "large-v3-turbo", kind: "speech", name: "Whisper Large v3 Turbo", summary: "Whisper's best trade of speed for accuracy", publisher: "OpenAI", bytes: 1.62 * GB, language: "multi", languages: "99 languages", speed: 3, accuracy: 4, rank: 3 },
  { id: "large-v3", kind: "speech", name: "Whisper Large v3", summary: "Most accurate Whisper, and the slowest", publisher: "OpenAI", bytes: 3.1 * GB, language: "multi", languages: "99 languages", speed: 1, accuracy: 5, rank: 4 },
  { id: "large-v2", kind: "speech", name: "Whisper Large v2", summary: "The previous large Whisper", publisher: "OpenAI", bytes: 3.09 * GB, language: "multi", languages: "99 languages", speed: 1, accuracy: 4, rank: 5 },
  { id: "medium", kind: "speech", name: "Whisper Medium", summary: "Balanced Whisper", publisher: "OpenAI", bytes: 1.53 * GB, language: "multi", languages: "99 languages", speed: 2, accuracy: 4, rank: 6 },
  { id: "small", kind: "speech", name: "Whisper Small", summary: "Light and quick", publisher: "OpenAI", bytes: 488 * MB, language: "multi", languages: "99 languages", speed: 3, accuracy: 3, rank: 7 },
  { id: "base", kind: "speech", name: "Whisper Base", summary: "Small download, rougher text", publisher: "OpenAI", bytes: 148 * MB, language: "multi", languages: "99 languages", speed: 4, accuracy: 2, rank: 8 },
  { id: "tiny", kind: "speech", name: "Whisper Tiny", summary: "Smallest download, for slow machines", publisher: "OpenAI", bytes: 78 * MB, language: "multi", languages: "99 languages", speed: 5, accuracy: 1, rank: 9 },
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
