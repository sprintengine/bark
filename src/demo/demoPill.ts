// The recording pill's states on the demo backend: open /index.html?demo&pill=<state>
// (and &theme=dark|light) at the window size that state gets (pill_window_bounds in
// lib.rs). Each state is reached through the pill's own code: the mocked backend
// answers as the real one would, and the pill is clicked or sent the real events.
//
//   hover         the ready capsule (the pointer over the idle handle)
//   starting      a start the backend hasn't confirmed yet
//   recording     listening, with a voice moving the waveform
//   transcribing  after finishing, while the words come back
//   inserted | copied | insertFailed | notCopied   where the words went
//   recopy        a dictation copied again from Home
//   polished      an AI-polished dictation, with Undo
//   undo          after Undo: the original copied
//   error         a start that failed (&error=<backend message> to pick one)
import { emit } from "@tauri-apps/api/event";

type Respond = (cmd: string, args: Record<string, unknown> | undefined) => unknown;

const never = () => new Promise<never>(() => {});

export function pillDemo(params: URLSearchParams): { respond: (fallback: Respond) => Respond } | null {
  const state = params.get("pill");
  if (state === null) return null;
  const startsRecording = ["recording", "transcribing", "inserted", "copied", "insertFailed", "notCopied"].includes(state);

  const respond = (fallback: Respond): Respond => (cmd, args) => {
    switch (cmd) {
      case "get_app_status":
        return startsRecording ? { state: "recording", message: "Recording", dictationId: 1 } : { state: "idle", message: "Ready" };
      case "start_recording":
        if (state === "error") throw params.get("error") ?? "Microphone permission was denied";
        return never();
      case "stop_and_transcribe":
        if (state === "transcribing") return never();
        return { transcript: "Running ten minutes late, start without me.", delivery: state };
      case "copy_original_transcript":
        return null;
      default:
        return fallback(cmd, args);
    }
  };

  const click = (id: string) => document.getElementById(id)?.click();
  window.addEventListener("load", () => {
    setTimeout(() => {
      switch (state) {
        case "hover":
          // Headless browsers have no pointer: keep the hover check satisfied.
          document.body.matches = (selector: string) => selector === ":hover" || Element.prototype.matches.call(document.body, selector);
          document.body.dispatchEvent(new MouseEvent("mouseenter"));
          break;
        case "recording":
          speak();
          break;
        case "polished":
        case "undo":
          void emit("transcript-history-updated", { item: { id: "d1", polished: true, rawText: "um so the original" } }).then(() => {
            if (state === "undo") click("undoPolishBtn");
          });
          break;
        case "recopy":
          void emit("transcript-copied", {});
          break;
        default:
          // Starting and the error click a ready pill; the outcomes finish a recording.
          click("recordBtn");
      }
    }, 50);
  });
  return { respond };
}

// A voice: syllables at about four a second, louder and quieter phrases.
function speak(): void {
  const start = performance.now();
  setInterval(() => {
    const t = (performance.now() - start) / 1000;
    const syllable = Math.max(0, Math.sin(t * Math.PI * 4.2)) ** 0.8;
    const phrase = 0.55 + 0.45 * Math.sin(t * 1.3);
    void emit("audio-level", { peak: 0, rms: 0.004 + 0.03 * syllable * phrase });
  }, 40);
}
