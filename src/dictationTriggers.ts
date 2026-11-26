// What a recording trigger does, given where the pill is. Every trigger (the
// record button, the toggle shortcut, a push-to-talk chord, hold-Fn) goes
// through these, so a live recording can always be stopped by any of them,
// whichever one started it.

export type DictationPhase = "idle" | "starting" | "recording" | "transcribing" | "error";

export interface TriggerState {
  phase: DictationPhase;
  /** A stop request for the current dictation is in flight. */
  stopPending: boolean;
  /** A cancel request for the current dictation is in flight. */
  cancelPending: boolean;
}

/**
 * - `start`: start a new recording.
 * - `stop`: stop the live recording and transcribe it.
 * - `stopAfterStart`: the recording is still starting; stop it as soon as
 *   capture is confirmed, rather than dropping the request.
 * - `cancel`: abandon the dictation being transcribed.
 * - `none`: nothing to do (the request is already under way).
 */
export type TriggerAction = "start" | "stop" | "stopAfterStart" | "cancel" | "none";

/** A press of the record button or the toggle shortcut. */
export function toggleAction(state: TriggerState): TriggerAction {
  switch (state.phase) {
    case "idle":
    case "error":
      return state.stopPending ? "none" : "start";
    case "starting":
      return "stopAfterStart";
    case "recording":
      return state.stopPending ? "none" : "stop";
    case "transcribing":
      return state.cancelPending ? "none" : "cancel";
  }
}

/** A hold-to-talk key going down (`pressed`) or coming up. */
export function holdAction(pressed: boolean, state: TriggerState): TriggerAction {
  if (pressed) {
    return (state.phase === "idle" || state.phase === "error") && !state.stopPending ? "start" : "none";
  }
  // Letting go ends a live recording, whichever trigger started it.
  if (state.phase === "starting") return "stopAfterStart";
  if (state.phase === "recording" && !state.stopPending) return "stop";
  return "none";
}

