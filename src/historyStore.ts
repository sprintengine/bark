import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

// The dictation history the sidebar's thread list shows, as on the Mac. The
// notes library is the durable list (every dictation is saved there, and
// notes typed on Home too); the transcript history keeps the recent ones'
// details (the app, what was heard before polish, the timings). A note is
// matched to its transcript by text and time, so a dictation shows where it
// went for as long as its details are kept.

export interface Timings { transcribeMs: number; speechModelMs: number; polishMs: number; totalMs: number }

export interface HistoryItem {
  id: string;
  createdAt: number;
  updatedAt: number;
  text: string;
  pinned: boolean;
  durationSeconds: number;
}

export interface TranscriptDetails {
  id: string;
  createdAt: number;
  text: string;
  appName?: string | null;
  rawText?: string | null;
  polished?: boolean;
  location?: string;
  backend?: string;
  model?: string | null;
  durationSeconds: number;
  timings?: Timings | null;
}

export interface Dictation extends HistoryItem {
  /** Typed (or dictated) into Home's box rather than spoken into an app. */
  isNote: boolean;
  details: TranscriptDetails | null;
}

export type HistoryFilter = "all" | "notes" | "pinned";

let items: Dictation[] = [];
let loaded = false;
const subscribers = new Set<() => void>();

export function dictations(): Dictation[] { return items; }
export function isLoaded(): boolean { return loaded; }
export function dictation(id: string | null | undefined): Dictation | null {
  return id ? items.find((item) => item.id === id) ?? null : null;
}

/** A dictation by its own id, or by the id of the transcript it was saved from. */
export function find(id: string | null | undefined): Dictation | null {
  return dictation(id) ?? (id ? items.find((item) => item.details?.id === id) ?? null : null);
}

export function subscribe(fn: () => void): () => void {
  subscribers.add(fn);
  return () => subscribers.delete(fn);
}

function norm(text: string): string { return text.replace(/\s+/g, " ").trim(); }

/** Pairs each note with the transcript it was saved from, if one is still kept. */
export function join(notes: HistoryItem[], history: TranscriptDetails[]): Dictation[] {
  const unused = new Set(history);
  const byText = new Map<string, TranscriptDetails[]>();
  for (const item of history) {
    const key = norm(item.text);
    byText.set(key, [...(byText.get(key) ?? []), item]);
  }
  const close = (a: number, b: number, ms: number) => Math.abs(a - b) <= ms;
  return [...notes].sort((a, b) => b.createdAt - a.createdAt).map((note) => {
    const isNote = !(note.durationSeconds > 0);
    let match: TranscriptDetails | undefined;
    if (!isNote) {
      match = byText.get(norm(note.text))?.find((item) => unused.has(item) && close(item.createdAt, note.createdAt, 120_000));
      // Edited since: the transcript saved within a few seconds of the note.
      match ??= history.find((item) => unused.has(item) && close(item.createdAt, note.createdAt, 5_000));
    }
    if (match) unused.delete(match);
    return { ...note, isNote, details: match ?? null };
  });
}

export async function refresh(): Promise<void> {
  const [notes, history] = await Promise.all([
    invoke<HistoryItem[]>("get_notes").catch(() => [] as HistoryItem[]),
    invoke<TranscriptDetails[]>("get_transcript_history").catch(() => [] as TranscriptDetails[]),
  ]);
  items = join(notes ?? [], history ?? []);
  loaded = true;
  for (const fn of subscribers) fn();
}

export function visible(query: string, filter: HistoryFilter): Dictation[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  return items.filter((item) => {
    if (filter === "notes" && !item.isNote) return false;
    if (filter === "pinned" && !item.pinned) return false;
    if (words.length === 0) return true;
    const hay = `${item.text} ${appName(item)}`.toLowerCase();
    return words.every((word) => hay.includes(word));
  });
}

// ── Words about a dictation (the Mac's DictationText) ──

export function appName(item: Dictation): string {
  if (item.isNote) return "Bark";
  return item.details?.appName?.trim() || "Dictation";
}

/** The first line, past a short greeting line ("Hi Aoife,") when more follows. */
export function title(item: Pick<HistoryItem, "text">): string {
  const lines = item.text.split(/\n/).map((line) => line.trim()).filter(Boolean);
  let line = lines[0];
  if (!line) return "Empty dictation";
  if (lines.length > 1 && line.endsWith(",") && line.split(/\s+/).length <= 4) line = lines[1];
  return line;
}

export function wordCount(text: string): number {
  const trimmed = text.trim();
  return trimmed ? trimmed.split(/\s+/).length : 0;
}

/** "Note · 12 words", "Polished · 38 words", "38 words". */
export function meta(item: Dictation): string {
  const n = wordCount(item.text);
  const words = `${n} word${n === 1 ? "" : "s"}`;
  if (item.isNote) return `Note · ${words}`;
  if (item.details?.polished) return `Polished · ${words}`;
  return words;
}

/** "now", "2m", "3h", "1d", "3w": compact, for the thread list. */
export function age(at: number, now = Date.now()): string {
  const s = Math.max(0, (now - at) / 1000);
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86_400) return `${Math.floor(s / 3600)}h`;
  if (s < 86_400 * 14) return `${Math.floor(s / 86_400)}d`;
  return `${Math.floor(s / (86_400 * 7))}w`;
}

/** Today, Yesterday, Previous 7 days, Earlier. */
export function groups(list: Dictation[], now = new Date()): { title: string; items: Dictation[] }[] {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const yesterday = today - 86_400_000;
  const week = today - 7 * 86_400_000;
  const titles = ["Today", "Yesterday", "Previous 7 days", "Earlier"];
  const buckets: Dictation[][] = [[], [], [], []];
  for (const item of list) {
    const at = item.createdAt;
    buckets[at >= today ? 0 : at >= yesterday ? 1 : at >= week ? 2 : 3].push(item);
  }
  return titles.map((t, i) => ({ title: t, items: buckets[i] })).filter((g) => g.items.length > 0);
}

/** Two letters for an app ("Google Docs" → GD, "Slack" → SL). */
export function monogram(name: string): string {
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
  return name.replace(/[^\p{L}\p{N}]/gu, "").slice(0, 2).toUpperCase();
}

/** A hue from the palette, stable for an app. */
export function monogramHue(name: string): number {
  let h = 0;
  for (const ch of name.toLowerCase()) h = (h * 31 + ch.codePointAt(0)!) & 0xffff;
  return h % 5;
}

void listen("notes-updated", () => void refresh()).catch(() => {});
void listen("transcript-history-updated", () => void refresh()).catch(() => {});
