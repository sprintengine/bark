import { invoke } from "@tauri-apps/api/core";
import { relativeTime } from "./updateModel";

// Home's "Recent dictations": the last few transcripts as cards, each with
// the app it went into, when, and a copy button. "See all" opens Notes.

export interface RecentDictation {
  id: string;
  createdAt: number;
  text: string;
  durationSeconds: number;
  appName?: string | null;
}

const SHOWN = 4;

/** Distinct apps among the dictations that recorded one, and how many did. */
export function appsUsed(history: RecentDictation[]): { count: number; named: number } {
  const named = history.filter((item) => item.appName && item.appName.trim());
  return { count: new Set(named.map((item) => item.appName!.trim())).size, named: named.length };
}

const COPY_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true"><rect x="8.5" y="8.5" width="11" height="12" rx="2.5"/><path d="M15.5 8.5V6a2.5 2.5 0 0 0-2.5-2.5H7A2.5 2.5 0 0 0 4.5 6v7A2.5 2.5 0 0 0 7 15.5h1.5"/></svg>';
const CHECK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>';

function card(item: RecentDictation, now: number): HTMLLIElement {
  const li = document.createElement("li");
  li.className = "recent-item";

  const body = document.createElement("div");
  body.className = "recent-body";
  const text = document.createElement("p");
  text.className = "recent-text";
  text.textContent = item.text;
  const meta = document.createElement("div");
  meta.className = "recent-meta";
  const app = item.appName?.trim();
  if (app) {
    const badge = document.createElement("span");
    badge.className = "recent-app";
    const glyph = document.createElement("span");
    glyph.className = "recent-app-glyph";
    glyph.setAttribute("aria-hidden", "true");
    glyph.textContent = app.slice(0, 1).toUpperCase();
    badge.append(glyph, app);
    meta.append(badge);
  }
  const when = document.createElement("time");
  when.dateTime = new Date(item.createdAt).toISOString();
  when.textContent = relativeTime(item.createdAt, now);
  when.title = new Date(item.createdAt).toLocaleString();
  meta.append(when);

  body.append(text, meta);

  const copy = document.createElement("button");
  copy.type = "button";
  copy.className = "icon-btn recent-copy";
  copy.setAttribute("aria-label", "Copy dictation");
  copy.title = "Copy";
  copy.innerHTML = COPY_ICON;
  copy.addEventListener("click", () => {
    void invoke("copy_transcript_history_item", { id: item.id })
      .then(() => {
        copy.innerHTML = CHECK_ICON;
        copy.classList.add("is-done");
        copy.setAttribute("aria-label", "Copied");
        setTimeout(() => {
          copy.innerHTML = COPY_ICON;
          copy.classList.remove("is-done");
          copy.setAttribute("aria-label", "Copy dictation");
        }, 1400);
      })
      .catch(() => { copy.title = "Could not copy"; });
  });

  li.append(body, copy);
  return li;
}

export function renderRecentDictations(list: HTMLElement, history: RecentDictation[], now = Date.now()): void {
  list.replaceChildren(...history.slice(0, SHOWN).map((item) => card(item, now)));
}
