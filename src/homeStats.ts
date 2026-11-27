import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as history from "./historyStore";

// Home's week in four numbers, as on the Mac: words this week, time saved
// (which opens the speed test), average pace, and how often a dictation went
// out without an edit. Before the first dictation, the setup card takes their
// place.

interface UsageStatsSummary {
  hasData: boolean;
  zeroEditRate7d?: number | null;
  zeroEditRate30d?: number | null;
  totalWords: number;
  totalDictations: number;
  totalRecordingSeconds: number;
  timeSavedSeconds: number;
  typingWpm: number;
  speakingWpm: number;
  thisWeekWords: number;
  lastWeekWords: number;
}

const TYPING_WPM = 40;
const byId = (id: string) => document.getElementById(id)!;

/** "3h 32m", "14m". */
export function hoursMinutes(seconds: number): string {
  const minutes = Math.floor(Math.max(0, seconds) / 60);
  return minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes}m`;
}

function render(summary: UsageStatsSummary | null): void {
  const has = Boolean(summary?.hasData && summary.totalDictations > 0);
  byId("homeEmpty").hidden = has;
  byId("homeStats").hidden = !has;
  if (!summary || !has) return;

  const words = summary.thisWeekWords;
  const weekAgo = Date.now() - 7 * 86_400_000;
  const dictations = history.dictations().filter((item) => !item.isNote && item.createdAt >= weekAgo).length;
  byId("statThisWeek").textContent = words.toLocaleString();
  byId("statWeekDelta").textContent = dictations > 0
    ? `${dictations.toLocaleString()} dictation${dictations === 1 ? "" : "s"}`
    : `${summary.lastWeekWords.toLocaleString()} last week`;

  const typing = summary.typingWpm > 0 ? summary.typingWpm : TYPING_WPM;
  const speaking = summary.speakingWpm;
  const saved = speaking > 0 ? (words / typing - words / speaking) * 60 : 0;
  byId("statTimeSaved").textContent = hoursMinutes(saved);
  byId("statTimeSavedSub").textContent = `vs typing at ${Math.round(typing)} wpm`;
  const tile = byId("statTimeSaved").closest<HTMLElement>(".tile");
  if (tile) tile.title = typing === TYPING_WPM ? "A typical typing pace. Take the speed test to use your own." : "Your typing speed from the speed test. Take it again.";

  byId("statWpm").textContent = speaking > 0 ? String(Math.round(speaking)) : "–";
  byId("statPaceNote").textContent = speaking > 0 ? "measured as you speak" : "speak a little more";

  const rate = summary.zeroEditRate7d ?? summary.zeroEditRate30d;
  byId("statZeroEdit").textContent = rate == null ? "–" : `${Math.round(rate * 100)}%`;
  byId("statZeroEditMeta").textContent = rate == null ? "once you have dictated" : summary.zeroEditRate7d != null ? "this week" : "last 30 days";
}

async function refresh(): Promise<void> {
  try {
    render(await invoke<UsageStatsSummary>("get_usage_stats"));
  } catch {
    render(null);
  }
}

void listen("transcript-history-updated", () => void refresh()).catch(() => {});
void listen("usage-stats-updated", () => void refresh()).catch(() => {});
history.subscribe(() => void refresh());
document.addEventListener("home-screen-changed", (event) => {
  if ((event as CustomEvent<{ screen: string }>).detail?.screen === "home") void refresh();
});
void refresh();
