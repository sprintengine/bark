// A stand-in backend for looking at the UI in a plain browser: `npm run dev`
// and open a window with `?demo` (e.g. /home.html?demo). Vite injects this
// module first on every page in dev only (vite.config.ts); it does nothing
// inside the real app or without `?demo`, and is never in a build.
//
// `?demo&theme=light` picks the theme; `?demo&empty` starts with no history.
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { onboardingDemo } from "./demoOnboarding";
import { pillDemo } from "./demoPill";

const params = new URLSearchParams(location.search);
const active = params.has("demo") && !("__TAURI_INTERNALS__" in window);

// `&platform=windows` draws Windows keys (Ctrl, Shift) on a Mac.
if (active && params.get("platform") === "windows") {
  Object.defineProperty(navigator, "platform", { get: () => "Win32" });
  Object.defineProperty(navigator, "userAgent", { get: () => "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" });
}

const MIN = 60_000;
const now = Date.now();

interface Item {
  id: string;
  createdAt: number;
  text: string;
  appName?: string;
  durationSeconds: number;
  rawText?: string;
  polished?: boolean;
  location?: string;
  backend?: string;
  model?: string;
  timings?: { transcribeMs: number; speechModelMs: number; polishMs: number; totalMs: number };
}

const HISTORY: Item[] = params.has("empty") ? [] : [
  { id: "d1", createdAt: now - 2 * MIN, appName: "Mail", durationSeconds: 11.4, polished: true,
    rawText: "Hi Aoife, um, so could you send the revised quote by Thursday, no wait, Friday, and copy in Declan? He's sort of handling the kitchen side now. Thanks, Sam.",
    text: "Hi Aoife,\n\nSo could you send the revised quote by Friday, and copy in Declan? He's sort of handling the kitchen side now.\n\nThanks,\nSam",
    timings: { transcribeMs: 120, speechModelMs: 410, polishMs: 48, totalMs: 182 } },
  { id: "d2", createdAt: now - 14 * MIN, appName: "Slack", durationSeconds: 3.1,
    text: "Running ten minutes late, start without me and I'll catch up.",
    timings: { transcribeMs: 96, speechModelMs: 150, polishMs: 0, totalMs: 140 } },
  { id: "d3", createdAt: now - 41 * MIN, appName: "Visual Studio Code", durationSeconds: 2.4,
    text: "Rename fetchQuote to loadQuote everywhere.",
    timings: { transcribeMs: 88, speechModelMs: 120, polishMs: 0, totalMs: 131 } },
  { id: "d4", createdAt: now - 70 * MIN, appName: "WhatsApp", durationSeconds: 2.2,
    text: "On the train now, home by half six" },
  { id: "d5", createdAt: now - 180 * MIN, appName: "OneNote", durationSeconds: 4.0,
    text: "Kitchen quote. Ask about the worktop, the sink and the extractor fan." },
  { id: "d6", createdAt: now - 200 * MIN, durationSeconds: 5.5,
    text: "Ideas for the practice newsletter: flu clinic dates, the new parking and the late Thursday surgery." },
  { id: "d7", createdAt: now - 26 * 60 * MIN, appName: "Google Docs", durationSeconds: 6.8,
    text: "Q4 review. Retention is up three points and support tickets are down by a fifth." },
  { id: "d8", createdAt: now - 28 * 60 * MIN, appName: "Outlook", durationSeconds: 7.2,
    text: "Thanks for the update. Tuesday works for me, I'll bring the drawings." },
  { id: "d9", createdAt: now - 30 * 60 * MIN, appName: "Slack", durationSeconds: 1.9,
    text: "Can you have a look at the build when you get a chance?" },
  { id: "d10", createdAt: now - 4 * 24 * 60 * MIN, appName: "Notepad", durationSeconds: 9.1,
    text: "Shopping: oat milk, coffee beans, two lemons and something for dinner on Friday." },
];

const NOTES = HISTORY.map((item) => ({
  id: `n-${item.id}`, createdAt: item.createdAt, updatedAt: item.createdAt, text: item.text,
  pinned: false, durationSeconds: item.durationSeconds,
}));

const SETTINGS: Record<string, unknown> = {
  transcriptionLocation: "local", model: "parakeet-tdt-0.6b-v3", remoteUrl: "http://build-box.example.ts.net:48173",
  remoteAuthToken: "", remoteTimeoutSeconds: 30, cloudAuthToken: "", language: "en", audioDevice: "",
  noiseSuppression: true, echoCancellation: true, inputGain: 2, postProcess: true,
  vocabularyHints: ["Aoife", "Declan", "Parakeet", "loadQuote"], enabledPacks: [],
  transcriptCorrections: [{ enabled: true, from: "cue four", to: "Q4", caseSensitive: false, wholePhrase: true, origin: "Manual", models: [] }],
  snippets: [{ enabled: true, trigger: "my address", expansion: "1 Example Street" }],
  alwaysOnTop: true, interactionSounds: true, maxRecordingSeconds: 600, noteRetentionMinutes: 0, useGpu: true,
  recordingShortcut: "CommandOrControl+Shift+Digit1", recordingShortcutMode: "toggle",
  transcriptStackShortcut: "Alt+Shift+KeyV", insertAtCursor: true, accessibilityInsert: false, fnPushToTalk: false,
  polishEnabled: false, polishProvider: "local", polishModel: "", polishTones: {}, polishLocalModelPath: "",
  polishLocalModelPrompt: "tagged", polishLocalAdapters: [], contextAwareness: false, learnedVocabularyHints: [],
  learnFromEdits: true, trainingCapture: false, trainingKeepDays: 30, formatAiDetection: false, superMode: "off",
  superModeModel: "large-v3-turbo", modelLinks: {},
};

const week = Array.from({ length: 7 }, (_, i) => ({
  dayLabel: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][i], words: [1820, 2210, 1540, 2400, 1980, 620, 1217][i], isToday: i === 6,
}));

const USAGE = params.has("empty")
  ? { hasData: false, totalWords: 0, totalDictations: 0, totalRecordingSeconds: 0, timeSavedSeconds: 0, typingWpm: 40, speakingWpm: 0, moneySavedUsd: 0, cloudRateUsdPerMinute: 0.006, currentStreak: 0, bestStreak: 0, thisWeekWords: 0, lastWeekWords: 0, week: [], months: [], unallocatedWords: 0 }
  : { hasData: true, totalWords: 48210, totalDictations: 1140, totalRecordingSeconds: 20100, timeSavedSeconds: 52200, typingWpm: 40, speakingWpm: 144,
      moneySavedUsd: 2.01, cloudRateUsdPerMinute: 0.006, currentStreak: 6, bestStreak: 14, thisWeekWords: 11787, lastWeekWords: 10950,
      week, months: [], unallocatedWords: 0, zeroEditRate7d: 0.86, zeroEditRate30d: 0.82 };

const SPEECH = ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2", "parakeet-ultra", "large-v3-turbo", "small", "base", "tiny"]
  .map((model, i) => ({ model, cached: i === 0 }));

function respond(cmd: string, args: Record<string, unknown> | undefined): unknown {
  switch (cmd) {
    case "get_settings": return SETTINGS;
    case "save_settings": case "save_shortcut_settings": Object.assign(SETTINGS, (args?.settings as object) ?? {}); return SETTINGS;
    case "get_transcript_history": return HISTORY;
    case "get_notes": return NOTES;
    case "add_note": {
      const note = { id: `n-${Date.now()}`, createdAt: Date.now(), updatedAt: Date.now(), text: String(args?.text ?? ""), pinned: false, durationSeconds: 0 };
      NOTES.unshift(note);
      return note;
    }
    case "get_usage_stats": return USAGE;
    case "get_dictation_models": return SPEECH;
    case "get_cloud_available": return false;
    case "get_app_status": return { state: "idle", message: "Ready" };
    case "get_local_model_catalog": return { polish: [], download: null, metadataError: null };
    case "get_transcription_model_status": return { model: SETTINGS.model, state: "ready", cached: true, ready: true, message: "" };
    case "get_update_status": return { state: "upToDate", currentVersion: "0.1.0", channel: "stable", buildChannel: "stable", lastCheckedAt: now - 3600_000 };
    case "get_permission_status": return { microphone: "granted", accessibility: "granted", inputMonitoring: "granted" };
    case "get_onboarding_state": return { completed: true };
    case "get_training_data_summary": return { count: 0, bytes: 0 };
    case "get_speed_test_summary": return { best: null, runs: [] };
    case "get_format_mappings": return [];
    case "get_learned_suggestions": return [];
    case "list_vocabulary_packs": return [];
    case "get_note_debug_status": return { available: false, enabled: false };
    case "get_cursor_preview_state": return null;
    case "plugin:event|listen": return Math.floor(Math.random() * 1e6);
    case "plugin:event|unlisten": case "plugin:event|emit": return null;
    default: return null;
  }
}

if (active) {
  mockWindows("home");
  // The pill (`&pill=<state>`, demoPill.ts) and the setup window (demoOnboarding.ts)
  // drive themselves with events, so those are mocked too.
  const driver = pillDemo(params) ?? onboardingDemo(params);
  const answer = driver ? driver.respond(respond) : respond;
  mockIPC((cmd, args) => answer(cmd, args as Record<string, unknown> | undefined), { shouldMockEvents: driver !== null });
  const theme = params.get("theme");
  if (theme === "light" || theme === "dark") localStorage.setItem("fairspoken.appearance", theme);
}
