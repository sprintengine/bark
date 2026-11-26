//! One dictation's life, from confirmed capture to its text being delivered,
//! and the rules that keep late work for one dictation (a finish, a cancel,
//! a watchdog or a deadline) from touching the next one.
//!
//! Every dictation gets an id when capture starts. Anything that runs later on
//! its behalf carries that id and only acts while it is still the current
//! dictation, so a slow finish of dictation N can never cancel, end or
//! otherwise clobber dictation N+1.

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
    /// Abandon dictation `id` while it finishes; its result is dropped.
    Finishing(u64),
    /// Nothing to cancel, for the reason given.
    Ignore(&'static str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Active {
    id: u64,
    phase: Phase,
    ended_by: Option<EndReason>,
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
        let superseded = self.current.map(|active| (active.id, active.phase));
        self.last_id += 1;
        self.current = Some(Active {
            id: self.last_id,
            phase: Phase::Recording,
            ended_by: None,
        });
        (self.last_id, superseded)
    }

    /// The current dictation, if any.
    pub fn active(&self) -> Option<(u64, Phase)> {
        self.current.map(|active| (active.id, active.phase))
    }

    /// Whether dictation `id` is the current one and still recording.
    pub fn is_recording(&self, id: u64) -> bool {
        self.active() == Some((id, Phase::Recording))
    }

    /// Capture is being stopped. Moves the recording dictation to finishing
    /// and returns its id, with `true`. A recording that is being cancelled
    /// keeps its cancel, so a stop racing it can never deliver it. A stop with
    /// no recording dictation tracked still gets an id of its own so the
    /// deadline and cancel rules hold for it, and returns `false`.
    pub fn begin_finishing(&mut self) -> (u64, bool) {
        if let Some(active) = self.current.as_mut() {
            if active.phase == Phase::Recording {
                active.phase = Phase::Finishing;
                return (active.id, true);
            }
        }
        self.last_id += 1;
        self.current = Some(Active {
            id: self.last_id,
            phase: Phase::Finishing,
            ended_by: None,
        });
        (self.last_id, false)
    }

    /// A cancel request, for dictation `requested` or (with `None`) for
    /// whichever dictation is current.
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
        match active.phase {
            Phase::Recording => {
                active.ended_by = Some(EndReason::Cancelled);
                CancelDecision::Recording(active.id)
            }
            Phase::Finishing => {
                active.ended_by = Some(EndReason::Cancelled);
                CancelDecision::Finishing(active.id)
            }
            Phase::Delivering => CancelDecision::Ignore("the text was already being delivered"),
        }
    }

    /// The finishing deadline for dictation `id` has passed. Returns `true`
    /// when that ends it, `false` when it is no longer current, has already
    /// been delivered, or was already ended.
    pub fn expire(&mut self, id: u64) -> bool {
        match self.current.as_mut() {
            Some(active)
                if active.id == id
                    && active.phase == Phase::Finishing
                    && active.ended_by.is_none() =>
            {
                active.ended_by = Some(EndReason::TimedOut);
                true
            }
            _ => false,
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
            .filter(|active| active.id == id)
            .and_then(|active| active.ended_by)
    }

    /// Dictation `id` is over. Returns `false`, and changes nothing, when a
    /// newer dictation has already taken its place.
    pub fn end(&mut self, id: u64) -> bool {
        if self.current.is_some_and(|active| active.id == id) {
            self.current = None;
            true
        } else {
            false
        }
    }
}

/// Room for the deterministic work, the cancellable polish pass and the
/// paste, on top of the transcription itself.
const FINISHING_BASE: Duration = Duration::from_secs(45);
/// No dictation may sit in "transcribing" longer than this.
const FINISHING_MAX: Duration = Duration::from_secs(15 * 60);

/// How long a dictation may take from capture stopping to its text being
/// ready, after which it is ended with an error. Generous on purpose: it is a
/// last resort for work that has hung, never a limit on a slow machine.
///
/// A remote host has its own response timeout, so it gets that much more. A
/// local finish can fall back to transcribing the whole recording at once,
/// which on a slow machine can take as long as the recording itself.
pub fn finishing_deadline(
    remote: bool,
    remote_timeout_seconds: u16,
    recording_seconds: f32,
) -> Duration {
    let transcription = if remote {
        Duration::from_secs(u64::from(remote_timeout_seconds))
    } else if recording_seconds.is_finite() {
        Duration::from_secs_f32(recording_seconds.clamp(0.0, 3600.0).ceil())
    } else {
        Duration::ZERO
    };
    (FINISHING_BASE + transcription).min(FINISHING_MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_late_finish_of_one_dictation_leaves_the_next_alone() {
        let mut lifecycle = DictationLifecycle::default();
        let (first, _) = lifecycle.begin_recording();
        assert_eq!(lifecycle.begin_finishing(), (first, true));

        // The next dictation starts before the first one's finish returns.
        let (second, superseded) = lifecycle.begin_recording();
        assert_eq!(superseded, Some((first, Phase::Finishing)));

        // The first one's late work finds it is no longer current.
        assert!(!lifecycle.end(first));
        assert!(!lifecycle.expire(first));
        assert_eq!(lifecycle.begin_delivery(first), Err(None));
        assert_eq!(lifecycle.end_reason(first), None);
        assert_eq!(
            lifecycle.request_cancel(Some(first)),
            CancelDecision::Ignore("it was for an earlier dictation")
        );
        assert!(lifecycle.is_recording(second));

        // And the second one can still be stopped, and delivered.
        assert_eq!(lifecycle.begin_finishing(), (second, true));
        assert_eq!(lifecycle.begin_delivery(second), Ok(()));
        assert!(lifecycle.end(second));
        assert_eq!(lifecycle.active(), None);
    }

    #[test]
    fn cancel_while_finishing_drops_the_result() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        lifecycle.begin_finishing();
        assert_eq!(
            lifecycle.request_cancel(Some(id)),
            CancelDecision::Finishing(id)
        );
        // A second press while it unwinds changes nothing.
        assert_eq!(
            lifecycle.request_cancel(None),
            CancelDecision::Ignore("the dictation is already ending")
        );
        // The deadline cannot relabel a cancel as a timeout.
        assert!(!lifecycle.expire(id));
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
        lifecycle.begin_finishing();
        assert_eq!(lifecycle.begin_delivery(id), Ok(()));
        assert_eq!(
            lifecycle.request_cancel(Some(id)),
            CancelDecision::Ignore("the text was already being delivered")
        );
        assert!(!lifecycle.expire(id));
    }

    #[test]
    fn the_deadline_ends_a_finishing_dictation_once() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, _) = lifecycle.begin_recording();
        // Not while it is still recording: the max-length watchdog owns that.
        assert!(!lifecycle.expire(id));
        lifecycle.begin_finishing();
        assert!(lifecycle.expire(id));
        assert!(!lifecycle.expire(id));
        assert_eq!(lifecycle.begin_delivery(id), Err(Some(EndReason::TimedOut)));
        assert_eq!(lifecycle.end_reason(id), Some(EndReason::TimedOut));
    }

    #[test]
    fn a_stop_with_nothing_tracked_still_gets_an_id() {
        let mut lifecycle = DictationLifecycle::default();
        let (id, tracked) = lifecycle.begin_finishing();
        assert!(!tracked);
        assert_eq!(lifecycle.active(), Some((id, Phase::Finishing)));
        assert_eq!(
            lifecycle.request_cancel(None),
            CancelDecision::Finishing(id)
        );
        let (next, _) = lifecycle.begin_recording();
        assert!(next > id);
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
        assert_eq!(lifecycle.begin_finishing(), (id, true));
        assert_eq!(
            lifecycle.begin_delivery(id),
            Err(Some(EndReason::Cancelled))
        );
        // Once the cancel has ended it, a later stop has nothing to finish.
        assert!(lifecycle.end(id));
        let (stop, tracked) = lifecycle.begin_finishing();
        assert!(!tracked);
        assert_ne!(stop, id);
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
    }

    #[test]
    fn finishing_deadline_covers_the_remote_timeout_and_long_local_recordings() {
        assert_eq!(finishing_deadline(true, 30, 600.0), Duration::from_secs(75));
        assert_eq!(finishing_deadline(false, 30, 9.2), Duration::from_secs(55));
        assert_eq!(
            finishing_deadline(false, 30, 600.0),
            Duration::from_secs(645)
        );
        assert_eq!(
            finishing_deadline(false, 30, f32::NAN),
            Duration::from_secs(45)
        );
        assert_eq!(finishing_deadline(false, 30, 1.0e9), FINISHING_MAX);
    }
}
