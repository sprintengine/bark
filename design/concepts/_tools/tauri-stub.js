// A fake Tauri bridge for rendering the real windows (home.html, index.html,
// cursor-preview.html, onboarding.html) in a plain browser. Injected before
// any page script by shot.mjs --stub. Every name, text and number here is
// fictional sample data.
//
// Options, read from window.__STUB_OPTIONS__ (shot.mjs --state '{...}'):
//   empty: true            a first-run profile: no stats, notes or history
//   platform: "macos"      what get_onboarding_state reports (macos|windows|linux)
//   permissions: {...}     microphone / accessibility / inputMonitoring states
//   downloading: true      a speech model download in progress
//
// window.__stubEmit(event, payload) fires a backend event at the page.
(() => {
  const options = window.__STUB_OPTIONS__ || {};
  const now = Date.now();
  const minute = 60_000;
  const hour = 60 * minute;
  const day = 24 * hour;

  // Monday-first, up to and including today; nothing after it.
  const today = (new Date().getDay() + 6) % 7;
  const week = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((dayLabel, i) => ({
    dayLabel, words: i > today ? 0 : [820, 1460, 640, 1980, 1210, 940, 1060][i], isToday: i === today,
  }));
  const months = ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10", "2026-11"].map((month, i) => ({
    month, words: [3200, 7400, 9100, 12800, 15400, 6100][i], isCurrentMonth: i === 5,
  }));
  const usage = options.empty
    ? { hasData: false, totalWords: 0, totalDictations: 0, totalRecordingSeconds: 0, timeSavedSeconds: 0, typingWpm: 40, speakingWpm: 0, moneySavedUsd: 0, cloudRateUsdPerMinute: 0.006, currentStreak: 0, bestStreak: 0, thisWeekWords: 0, lastWeekWords: 0, week: [], months: [], unallocatedWords: 0 }
    : { hasData: true, zeroEditRate30d: 0.82, polishedZeroEditRate30d: 0.86, rawZeroEditRate30d: 0.71, totalWords: 48211, totalDictations: 1342, totalRecordingSeconds: 21400, timeSavedSeconds: 50900, typingWpm: 40, speakingWpm: 142, moneySavedUsd: 2.14, cloudRateUsdPerMinute: 0.006, currentStreak: 9, bestStreak: 23, thisWeekWords: 6110, lastWeekWords: 5200, week, months, unallocatedWords: 0 };

  const timings = (total) => ({ transcribeMs: Math.round(total * 0.3), speechModelMs: 640, polishMs: 410, totalMs: total });
  const history = options.empty ? [] : [
    { text: "Thanks for sending the draft over. I've added two comments on the budget section; the rest looks ready to go out on Friday.", appName: "Mail", ago: 2 * minute, seconds: 9.1, polished: true },
    { text: "Can we move the design review to Thursday afternoon? Tuesday is filling up fast.", appName: "Slack", ago: 26 * minute, seconds: 5.2, polished: true },
    { text: "Refactor the download queue so a paused model resumes where it stopped after the laptop wakes from sleep.", appName: "Code", ago: 1 * hour + 12 * minute, seconds: 7.8, polished: false },
    { text: "Shopping list: oat milk, two lemons, basil, and the good coffee from the market.", appName: "Notes", ago: 3 * hour, seconds: 4.6, polished: true },
    { text: "Running about ten minutes late, save me a seat near the front.", appName: "Messages", ago: 1 * day + 2 * hour, seconds: 3.4, polished: true },
    { text: "Summary of the call: the pilot starts in January, two sites, and we review numbers after six weeks.", appName: "Docs", ago: 1 * day + 5 * hour, seconds: 8.7, polished: true },
  ].map((item, i) => ({
    id: `transcript-${now - item.ago}`,
    createdAt: now - item.ago,
    text: item.text,
    backend: "parakeet",
    location: "local",
    durationSeconds: item.seconds,
    polished: item.polished,
    appName: item.appName,
    timings: timings(520 + i * 37),
  }));
  const notes = history.map((item, i) => ({
    id: `note-${i + 1}`, createdAt: item.createdAt, updatedAt: item.createdAt, text: item.text, pinned: i === 1, durationSeconds: item.durationSeconds,
  }));

  const settings = {
    model: "parakeet-tdt-0.6b-v3", transcriptionLocation: "local", polishEnabled: true, polishProvider: "local", polishModel: "qwen3.5-2b",
    cloudAuthToken: "", language: "en", recordingShortcut: "Alt+Space", recordingShortcutMode: "toggle", transcriptStackShortcut: "CommandOrControl+Shift+Digit2",
    interactionSounds: true, insertAtCursor: true, fnPushToTalk: false, trainingCapture: false, trainingRetentionDays: 30, audioDevice: "",
    vocabularyHints: [], transcriptCorrections: [], snippets: [], polishTones: {}, modelLinks: {}, enabledPacks: [],
    favoriteModels: ["parakeet-tdt-0.6b-v3"],
  };
  const speechIds = ["parakeet-tdt-0.6b-v3", "parakeet-ultra", "parakeet-tdt-0.6b-v2", "tiny", "base", "small", "medium", "large-v2", "large-v3", "large-v3-turbo"];
  const cached = new Set(options.empty ? [] : ["parakeet-tdt-0.6b-v3", "base"]);
  const polish = [
    { id: "speakoflow-mini", name: "SpeakoFlow Mini", publisher: "SpeakoFlow", description: "Trained for dictation cleanup · resolves spoken corrections, leaves clean text alone · English · roughly 1–2 GB memory", bytes: 833591776 },
    { id: "qwen3.5-0.8b", name: "Qwen3.5 0.8B", publisher: "Qwen", description: "Smallest download · punctuation and fillers only, unreliable at spoken corrections · roughly 1–2 GB memory", bytes: 563036064 },
    { id: "qwen3.5-2b", name: "Qwen3.5 2B", publisher: "Qwen", description: "Balanced · lists, quotes and most spoken corrections · roughly 2–4 GB memory", bytes: 1270808032 },
    { id: "qwen3.5-4b", name: "Qwen3.5 4B", publisher: "Qwen", description: "Best cleanup · resolves corrections and restarts reliably · slower, roughly 4–6 GB memory", bytes: 2740937888 },
  ].map((m) => ({
    ...m, installed: !options.empty && m.id === "qwen3.5-2b", selected: !options.empty && m.id === settings.polishModel, loaded: false,
    source: `https://huggingface.co/example/${m.id}`, downloads: 18000 + m.bytes % 9000, supported: true,
  }));
  const permissions = Object.assign({ platform: options.platform || "macos", microphone: "granted", accessibility: "denied", inputMonitoring: "not-needed" }, options.permissions || {});

  const handlers = {
    get_usage_stats: () => usage,
    get_transcript_history: () => history,
    get_notes: () => notes,
    get_settings: () => ({ ...settings }),
    save_settings: ({ settings: next }) => { Object.assign(settings, next); emit("settings-updated", { ...settings }); return { ...settings }; },
    save_shortcut_settings: () => ({ ...settings }),
    get_dictation_models: () => speechIds.map((model) => ({ model, cached: cached.has(model), modelPath: "", message: "" })),
    get_local_model_catalog: () => ({ polish, download: null, metadataError: null }),
    get_cloud_available: () => false,
    get_app_status: () => ({ state: "idle", message: "Ready" }),
    get_update_status: () => ({ state: "idle", currentVersion: "0.1.0", channel: "stable" }),
    get_transcription_model_status: () => options.downloading
      ? { model: settings.model, cached: false, state: "loading", message: "Downloading Parakeet · 1.2 GB / 2.5 GB" }
      : { model: settings.model, cached: true, state: "ready", message: "Ready" },
    get_training_data_summary: () => ({ count: 0, bytes: 0 }),
    get_speed_test_summary: () => null,
    get_note_debug_status: () => ({ available: false, enabled: false }),
    get_learned_suggestions: () => [],
    get_format_mappings: () => [],
    list_vocabulary_packs: () => [],
    get_cursor_preview_state: () => ({ sessionId: 1, revision: 1, phase: "idle", text: "", polished: false, remote: false, polishing: false }),
    search_hugging_face_models: () => ({ models: [], cached: true }),
    layout_pill_window: () => null,
    set_cursor_preview_size: () => null,
    copy_transcript_history_item: ({ id }) => history.find((item) => item.id === id),
    start_recording: () => 300,
    get_onboarding_state: () => ({ completed: Boolean(options.onboarded), platform: permissions.platform }),
    get_permission_status: () => ({ ...permissions }),
    request_permission: ({ kind }) => { permissions[kind] = "granted"; return { ...permissions }; },
    complete_onboarding: () => null,
    open_onboarding_window: () => null,
    open_home_window: () => null,
    begin_prepare_transcription_model: () => null,
  };

  const callbacks = new Map();
  const listeners = new Map();
  let next = 1;
  function emit(event, payload) {
    for (const id of listeners.get(event) || []) callbacks.get(id)?.({ event, id, payload });
  }
  window.__stubEmit = emit;

  const label = /onboarding/.test(location.pathname) ? "onboarding"
    : /cursor-preview/.test(location.pathname) ? "cursor-preview"
    : /index\.html|\/$/.test(location.pathname) ? "main" : "home";
  window.__TAURI_INTERNALS__ = {
    metadata: { currentWindow: { label }, currentWebview: { windowLabel: label, label } },
    transformCallback: (cb) => { const id = next++; callbacks.set(id, cb); return id; },
    unregisterCallback: (id) => callbacks.delete(id),
    convertFileSrc: (p) => p,
    invoke: async (cmd, args = {}) => {
      if (cmd === "plugin:event|listen") {
        listeners.set(args.event, [...(listeners.get(args.event) || []), args.handler]);
        return args.handler;
      }
      if (cmd.startsWith("plugin:global-shortcut|is_registered")) return true;
      if (cmd.startsWith("plugin:")) return null;
      if (cmd in handlers) return handlers[cmd](args);
      return null;
    },
  };
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
})();
