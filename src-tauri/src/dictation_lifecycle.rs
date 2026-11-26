//! One dictation's life, from confirmed capture to its text being delivered,
//! and the rules that keep late work for one dictation (a finish, a cancel,
//! a watchdog or a deadline) from touching the next one.
//!
//! Every dictation gets an id when capture starts, and signals of its own that
//! its work watches. Anything that runs later on its behalf carries that id
//! and only acts while it is still the current dictation, so a slow finish of
//! dictation N can never cancel, end or otherwise clobber dictation N+1.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::time::Duration;

/// Where the current dictation is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// The microphone is live.
    Recording,
    /// Capture has stopped; the transcript is being finished and polished.
    Finishing,
    /// The text is being written to the clipboard and inserted. Too late to
    /// cancel or time out.
    Delivering,
}

/// Why a dictation was ended before its text was delivered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    Cancelled,
    TimedOut,
}

/// What a cancel request should do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CancelDecision {
    /// Discard the live recording `id`: stop capture and drop its audio.
    Recording(u64),
    /// Dictation `id` is finishing; its signals are now set, so its work
    /// stops at its next check and its result is dropped.
    Finishing(u64),
    /// Nothing to cancel, for the reason given.
    Ignore(&'static str),
}

/// What the finishing deadline does when it passes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Expiry {
    /// The transcript is already there: only the polish pass is stopped, and
    /// the unpolished text is delivered.
    StopPolish,
    /// The dictation is ended with a timeout; its signals are set.
    End,
    /// Nothing to do: the dictation is no longer current, was delivered, or
    /// was already ended.
    NotCurrent,
}

/// The flags one dictation's work watches. Each dictation has its own, so a
/// cancel or deadline for one can never reach another.
#[derive(Clone, Debug, Default)]
pub struct DictationSignals {
    cancel: Arc<AtomicBool>,
    stop_polish: Arc<AtomicBool>,
}

impl DictationSignals {
    /// Set when the dictation is cancelled or timed out: everything stops.
    pub fn cancel_flag(&self) -> &AtomicBool {
        &self.cancel
    }

    /// Set when the polish pass must stop: on a cancel, or when the deadline
    /// passes after the transcript is ready.
    pub fn polish_stop_flag(&self) -> &AtomicBool {
        &self.stop_polish
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }

    /// Cancels everything (also used when the app quits).
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
        self.stop_polish.store(true, Ordering::SeqCst);
    }

    fn stop_polish(&self) {
        self.stop_polish.store(true, Ordering::SeqCst);
    }
}

/// A dictation whose capture is being stopped.
#[derive(Clone, Debug)]
pub struct Finishing {
    pub id: u64,
    /// False when no recording dictation was tracked (which should not happen).
    pub tracked: bool,
    pub signals: DictationSignals,
}

#[derive(Clone, Debug)]
struct Active {
    id: u64,
    phase: Phase,
    ended_by: Option<EndReason>,
    /// The raw transcript is ready; what is left is polish and delivery.
    transcribed: bool,
    polish_stopped: bool,
    /// Claimed by the max-duration watchdog, which is waiting for the
    /// dictation lock to commit it.
    awaiting_commit: bool,
    signals: DictationSignals,
}

impl Active {
    fn new(id: u64, phase: Phase) -> Self {
        Self {
            id,
            phase,
            ended_by: None,
            transcribed: false,
            polish_stopped: false,
            awaiting_commit: false,
            signals: DictationSignals::default(),
        }
    }
}

#[derive(Debug, Default)]
pub struct DictationLifecycle {
    last_id: u64,
    current: Option<Active>,
}

impl DictationLifecycle {
    /// A new dictation whose capture is now live. Returns its id and the
    /// dictation it replaced, if one was somehow still active (an anomaly the
    /// caller logs: it means an earlier dictation never ended).
    pub fn begin_recording(&mut self) -> (u64, Option<(u64, Phase)>) {
        let superseded = self.active();
        self.last_id += 1;
        self.current = Some(Active::new(self.last_id, Phase::Recording));
        (self.last_id, superseded)
    }

    /// The recording the watchdog claimed and has yet to commit, unless it has
    /// been cancelled since. A start must wait for it: it still needs the
    /// transcription session.
    pub fn awaiting_commit(&self) -> Option<u64> {
        self.current
            .as_ref()
            .filter(|active| {
                active.awaiting_commit
                    && active.phase == Phase::Finishing
                    && active.ended_by.is_none()
            })
            .map(|active| active.id)
    }

    /// The current dictation, if any.
    pub fn active(&self) -> Option<(u64, Phase)> {
        self.current.as_ref().map(|active| (active.id, active.phase))
    }

    /// Whether dictation `id` is the current one and still recording.
    pub fn is_recording(&self, id: u64) -> bool {
        self.active() == Some((id, Phase::Recording))
    }

    /// Capture is being stopped. Moves the recording dictation to finishing.
    /// A recording that is being cancelled keeps its cancel, so a stop racing
    /// it can never deliver it. A stop with no recording dictation tracked
    /// still gets an id of its own so the deadline and cancel rules hold for
    /// it.
    pub fn begin_finishing(&mut self) -> Finishing {
        if let Some(active) = self.current.as_mut() {
            if active.phase == Phase::Recording {
                active.phase = Phase::Finishing;
                return Finishing {
                    id: active.id,
                    tracked: true,
                    signals: active.signals.clone(),
                };
            }
        }
        self.last_id += 1;
        let active = Active::new(self.last_id, Phase::Finishing);
        let finishing = Finishing {
            id: active.id,
            tracked: false,
            signals: active.signals.clone(),
        };
        self.current = Some(active);
        finishing
    }

    /// Claims recording `id` for a stop that cannot take the operation lock
    /// yet (the max-duration watchdog), so no other stop finishes it too.
    /// Returns its signals, or `None` when it is no longer a live recording.
    pub fn claim_for_stop(&mut self, id: u64) -> Option<DictationSignals> {
        match self.current.as_mut() {
            Some(active)
                if active.id == id
                    && active.phase == Phase::Recording
                    && active.ended_by.is_none() =>
            {
                active.phase = Phase::Finishing;
                active.awaiting_commit = true;
                Some(active.signals.clone())
            }
            _ => None,
        }
    }

    /// A cancel request, for dictation `requested` or (with `None`) for
    /// whichever dictation is current. A cancel that applies sets the
    /// dictation's signals before it returns.
    pub fn request_cancel(&mut self, requested: Option<u64>) -> CancelDecision {
        let Some(active) = self.current.as_mut() else {
            return CancelDecision::Ignore("no dictation is active");
        };
        if requested.is_some_and(|id| id != active.id) {
            return CancelDecision::Ignore("it was for an earlier dictation");
        }
        if active.ended_by.is_some() {
            return CancelDecision::Ignore("the dictation is already ending");
        }
        let decision = match active.phase {
            Phase::Recording => CancelDecision::Recording(active.id),
            Phase::Finishing => CancelDecision::Finishing(active.id),
            Phase::Delivering => {
                return CancelDecision::Ignore("the text was already being delivered")
            }
        };
        active.ended_by = Some(EndReason::Cancelled);
        active.signals.cancel();
        decision
    }

    /// Dictation `id` has its raw transcript: from now on the deadline only
    /// stops the polish pass.
    pub fn transcribed(&mut self, id: u64) {
        if let Some(active) = self.current.as_mut().filter(|active| active.id == id) {
            active.transcribed = true;
        }
    }

    /// The finishing deadline for dictation `id` has passed. Before the
    /// transcript is ready, or a second time once the polish was already
    /// stopped, that ends the dictation; after it, only the polish stops.
    pub fn expire(&mut self, id: u64) -> Expiry {
        match self.current.as_mut() {
            Some(active)
                if active.id == id
                    && active.phase == Phase::Finishing
                    && active.ended_by.is_none() =>
            {
                if active.transcribed && !active.polish_stopped {
                    active.polish_stopped = true;
                    active.signals.stop_polish();
                    Expiry::StopPolish
                } else {
                    active.ended_by = Some(EndReason::TimedOut);
                    active.signals.cancel();
                    Expiry::End
                }
            }
            _ => Expiry::NotCurrent,
        }
    }

    /// The text for dictation `id` is ready. Returns `Ok` when it may be
    /// delivered, or why not: it was ended (cancelled or timed out), or it is
    /// no longer the current dictation (`None`).
    pub fn begin_delivery(&mut self, id: u64) -> Result<(), Option<EndReason>> {
        match self.current.as_mut() {
            Some(active) if active.id == id => {
                if let Some(reason) = active.ended_by {
                    return Err(Some(reason));
                }
                active.phase = Phase::Delivering;
                Ok(())
            }
            _ => Err(None),
        }
    }

    /// Why dictation `id` was ended early, while it is still current.
    pub fn end_reason(&self, id: u64) -> Option<EndReason> {
        self.current
            .as_ref()
            .filter(|active| active.id == id)
            .and_then(|active| active.ended_by)
    }

    /// Dictation `id` is over. Returns `false`, and changes nothing, when a
    /// newer dictation has already taken its place.
    pub fn end(&mut self, id: u64) -> bool {
        if self.current.as_ref().is_some_and(|active| active.id == id) {
            self.current = None;
            true
        } else {
            false
        }
    }
}

/// Why a cancellable wait ended without a value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaitError {
    Cancelled,
    /// The sender went away without sending.
    Disconnected,
}

/// Waits for the value on `rx`, checking `cancel` every `poll`. A cancelled
/// wait walks away: whatever is sent later is dropped with the receiver.
pub fn recv_unless_cancelled<T>(
    rx: &Receiver<T>,
    cancel: &AtomicBool,
    poll: Duration,
) -> Result<T, WaitError> {
    loop {
        if cancel.load(Ordering::SeqCst) {
            return Err(WaitError::Cancelled);
        }
        match rx.recv_timeout(poll) {
            Ok(value) => return Ok(value),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Err(WaitError::Disconnected),
        }
    }
}

/// Room for the deterministic work, the cancellable polish pass and the
/// paste, on top of the transcription itself.
const FINISHING_BASE: Duration = Duration::from_secs(45);
/// A local finish may run this many times slower than the recording, as a
/// large model on CPU can, before the deadline counts it as hung.
const LOCAL_SLOWDOWN_ALLOWANCE: f32 = 3.0;
/// No dictation may sit in "transcribing" longer than this.
const FINISHING_MAX: Duration = Duration::from_secs(45 * 60);

/// How long a dictation may take from capture stopping to its transcript
/// being ready, after which it is ended with an error (or, once the
/// transcript is ready, its polish is stopped). Generous on purpose: it is a
/// last resort for work that has hung, never a limit on a slow machine.
///
/// A remote host has its own response timeout, so it gets that much more. A
/// local finish can fall back to transcribing the whole recording at once,
/// which on a slow machine can take longer than the recording itself.
pub fn finishing_deadline(
    remote: bool,
    remote_timeout_seconds: u16,
    recording_seconds: f32,
) -> Duration {
    let transcription = if remote {
        Duration::from_secs(u64::from(remote_timeout_seconds))
    } else if recording_seconds.is_finite() {
        Duration::from_secs_f32(
            (recording_seconds.clamp(0.0, 3600.0) * LOCAL_SLOWDOWN_ALLOWANCE).ceil(),
        )
    } else {
        Duration::ZERO
    };
    (FINISHING_BASE + transcription).min(FINISHING_MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn is_set(flag: &AtomicBool) -> bool {
        flag.load(Ordering::SeqCst)
    }

    #[test]
    fn a_late_finish_of_one_dictation_leaves_the_next_alone() {
        let mut lifecycle = DictationLifecycle::default();
        let (first, _) = lifecycle.begin_recording();
        let finishing = lifecycle.begin_finishing();
        assert_eq!((finishing.id, finishing.tracked), (first, true));

        // The next dictation starts before the first one's finish returns.
        let (second, superseded) = lifecycle.begin_recording();
        assert_eq!(superseded, Some((first, Phase::Finishing)));

        // The first one's late work finds it is no longer current.
        assert!(!lifecycle.end(first));
        assert_eq!(lifecycle.expire(first), Expiry::NotCurrent);
        assert_eq!(lifecycle.begin_delivery(first), Err(None));
        assert_eq!(lifecycle.end_reason(first), None);
        assert_eq!(
            lifecycle.request_cancel(Some(first)),
            CancelDecision::Ignore("it was for an earlier dictation")
        );
        assert!(lifecycle.is_recording(second));

        // And the second one can still be stopped, and delivered, with
        // signals of its own that nothing above has touched.
        let next = lifecycle.begin_finishing();
        assert_eq!((next.id, next.tracked), (second, true));
        assert!(!next.signals.is_cancelled());
        assert_eq!(lifecycle.begin_delivery(second), Ok(()));
        assert!(lifecycle.end(second));
        assert_eq!(lifecycle.active(), None);
    }

    #[test]
    fn cancelling_one_dictation_never_signals_the_next() {
        let mut lifecycle = DictationLifecycle::default();
        lifecycle.begin_recording();
        let first = lifecycle.begin_finishing();
        assert_eq!(
            lifecycle.request_cancel(Some(first.id)),
            CancelDecision::Finishing(first.id)
        );
        assert!(first.signals.is_cancelled());
        lifecycle.end(first.id);
        lifecycle.begin_recording();
        let second = lifecycle.begin_finishing();
        assert!(!second.signals.is_cancelled());
        assert!(!is_set(second.signals.polish_stop_flag()));
    }

    #[test]
    fn cancel_while_finishing_drops_the_result() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        let finishing = lifecycle.begin_finishing();
        assert_eq!(
            lifecycle.request_cancel(Some(id)),
            CancelDecision::Finishing(id)
        );
        assert!(finishing.signals.is_cancelled());
        assert!(is_set(finishing.signals.polish_stop_flag()));
        // A second press while it unwinds changes nothing.
        assert_eq!(
            lifecycle.request_cancel(None),
            CancelDecision::Ignore("the dictation is already ending")
        );
        // The deadline cannot relabel a cancel as a timeout.
        assert_eq!(lifecycle.expire(id), Expiry::NotCurrent);
        assert_eq!(
            lifecycle.begin_delivery(id),
            Err(Some(EndReason::Cancelled))
        );
        assert_eq!(lifecycle.end_reason(id), Some(EndReason::Cancelled));
        assert!(lifecycle.end(id));
    }

    #[test]
    fn cancel_while_recording_discards_the_recording() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        assert_eq!(
            lifecycle.request_cancel(None),
            CancelDecision::Recording(id)
        );
        assert!(lifecycle.end(id));
        assert_eq!(
            lifecycle.request_cancel(Some(id)),
            CancelDecision::Ignore("no dictation is active")
        );
    }

    #[test]
    fn cancel_after_delivery_began_is_too_late() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        let finishing = lifecycle.begin_finishing();
        assert_eq!(lifecycle.begin_delivery(id), Ok(()));
        assert_eq!(
            lifecycle.request_cancel(Some(id)),
            CancelDecision::Ignore("the text was already being delivered")
        );
        assert_eq!(lifecycle.expire(id), Expiry::NotCurrent);
        assert!(!finishing.signals.is_cancelled());
    }

    #[test]
    fn the_deadline_ends_a_dictation_still_waiting_for_its_transcript() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        // Not while it is still recording: the max-length watchdog owns that.
        assert_eq!(lifecycle.expire(id), Expiry::NotCurrent);
        let finishing = lifecycle.begin_finishing();
        assert_eq!(lifecycle.expire(id), Expiry::End);
        assert!(finishing.signals.is_cancelled());
        assert_eq!(lifecycle.expire(id), Expiry::NotCurrent);
        assert_eq!(
            lifecycle.begin_delivery(id),
            Err(Some(EndReason::TimedOut))
        );
        assert_eq!(lifecycle.end_reason(id), Some(EndReason::TimedOut));
    }

    #[test]
    fn past_the_deadline_a_finished_transcript_is_delivered_unpolished() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        let finishing = lifecycle.begin_finishing();
        lifecycle.transcribed(id);
        assert_eq!(lifecycle.expire(id), Expiry::StopPolish);
        // Only the polish stops; the dictation goes on to be delivered.
        assert!(is_set(finishing.signals.polish_stop_flag()));
        assert!(!finishing.signals.is_cancelled());
        assert_eq!(lifecycle.begin_delivery(id), Ok(()));
    }

    #[test]
    fn a_dictation_stuck_after_its_polish_was_stopped_is_ended() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        let finishing = lifecycle.begin_finishing();
        lifecycle.transcribed(id);
        assert_eq!(lifecycle.expire(id), Expiry::StopPolish);
        assert_eq!(lifecycle.expire(id), Expiry::End);
        assert!(finishing.signals.is_cancelled());
        assert_eq!(
            lifecycle.begin_delivery(id),
            Err(Some(EndReason::TimedOut))
        );
    }

    #[test]
    fn a_stop_with_nothing_tracked_still_gets_an_id() {
        let mut lifecycle = DictationLifecycle::default();
        let finishing = lifecycle.begin_finishing();
        assert!(!finishing.tracked);
        assert_eq!(lifecycle.active(), Some((finishing.id, Phase::Finishing)));
        assert_eq!(
            lifecycle.request_cancel(None),
            CancelDecision::Finishing(finishing.id)
        );
        let (next, _) = lifecycle.begin_recording();
        assert!(next > finishing.id);
    }

    #[test]
    fn a_stop_racing_a_cancel_cannot_deliver_the_recording() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        assert_eq!(
            lifecycle.request_cancel(Some(id)),
            CancelDecision::Recording(id)
        );
        // The stop lands before the cancel has torn the recording down.
        let finishing = lifecycle.begin_finishing();
        assert_eq!((finishing.id, finishing.tracked), (id, true));
        assert!(finishing.signals.is_cancelled());
        assert_eq!(
            lifecycle.begin_delivery(id),
            Err(Some(EndReason::Cancelled))
        );
        // Once the cancel has ended it, a later stop has nothing to finish.
        assert!(lifecycle.end(id));
        let stop = lifecycle.begin_finishing();
        assert!(!stop.tracked);
        assert_ne!(stop.id, id);
    }

    #[test]
    fn the_watchdog_only_acts_on_its_own_recording() {
        let mut lifecycle = DictationLifecycle::default();
        let (first, _) = lifecycle.begin_recording();
        lifecycle.begin_finishing();
        lifecycle.end(first);
        let (second, _) = lifecycle.begin_recording();
        assert!(!lifecycle.is_recording(first));
        assert!(lifecycle.is_recording(second));
        assert!(lifecycle.claim_for_stop(first).is_none());
    }

    #[test]
    fn a_watchdog_claim_keeps_other_stops_off_the_recording() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        let signals = lifecycle.claim_for_stop(id).expect("live recording");
        assert_eq!(lifecycle.active(), Some((id, Phase::Finishing)));
        assert!(lifecycle.claim_for_stop(id).is_none());
        assert_eq!(lifecycle.awaiting_commit(), Some(id));
        // A cancel while the claimed recording waits still reaches it.
        assert_eq!(
            lifecycle.request_cancel(Some(id)),
            CancelDecision::Finishing(id)
        );
        assert!(signals.is_cancelled());
        // Once cancelled it holds up no start.
        assert_eq!(lifecycle.awaiting_commit(), None);
        // A cancelled recording cannot be claimed.
        let (next, _) = lifecycle.begin_recording();
        lifecycle.request_cancel(Some(next));
        assert!(lifecycle.claim_for_stop(next).is_none());
    }

    #[test]
    fn a_cancellable_wait_returns_the_value_or_walks_away() {
        let poll = Duration::from_millis(10);
        let never = AtomicBool::new(false);

        let (tx, rx) = std::sync::mpsc::channel();
        tx.send(7).unwrap();
        assert_eq!(recv_unless_cancelled(&rx, &never, poll), Ok(7));

        let (tx, rx) = std::sync::mpsc::channel::<u8>();
        drop(tx);
        assert_eq!(
            recv_unless_cancelled(&rx, &never, poll),
            Err(WaitError::Disconnected)
        );

        // A sender that never answers, as with a decode that hangs.
        let (tx, rx) = std::sync::mpsc::channel::<u8>();
        let cancel = Arc::new(AtomicBool::new(false));
        let setter = Arc::clone(&cancel);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            setter.store(true, Ordering::SeqCst);
        });
        let started = std::time::Instant::now();
        assert_eq!(
            recv_unless_cancelled(&rx, &cancel, poll),
            Err(WaitError::Cancelled)
        );
        assert!(started.elapsed() < Duration::from_secs(2));
        drop(tx);
    }

    #[test]
    fn finishing_deadline_covers_the_remote_timeout_and_slow_local_models() {
        assert_eq!(finishing_deadline(true, 30, 600.0), Duration::from_secs(75));
        assert_eq!(finishing_deadline(false, 30, 9.2), Duration::from_secs(73));
        assert_eq!(
            finishing_deadline(false, 30, 600.0),
            Duration::from_secs(1845)
        );
        assert_eq!(
            finishing_deadline(false, 30, f32::NAN),
            Duration::from_secs(45)
        );
        assert_eq!(finishing_deadline(false, 30, 1.0e9), FINISHING_MAX);
    }
}
