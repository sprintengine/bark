//! macOS-only input integration: insert-at-cursor via a synthesized ⌘V and
//! hold-Fn push-to-talk via a listen-only CGEventTap.
//!
//! Both paths sit behind macOS privacy permissions. Posting keyboard events
//! needs Accessibility; installing an event tap on keyboard traffic needs
//! Input Monitoring. Failures must stay observable: callers surface them as
//! backend events instead of silently falling back.

use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::mach_port::CFMachPortRef;
use core_foundation::runloop::{kCFRunLoopCommonModes, CFRunLoop};
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
    CGEventType, CallbackResult, EventField,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use serde::Serialize;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

/// Virtual key code for `V` on the ANSI layout, the key ⌘V paste expects.
const KEY_CODE_V: u16 = 9;
/// Virtual key code reported by `flagsChanged` events for the Fn/Globe key.
const KEY_CODE_FN: i64 = 63;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    static kAXTrustedCheckOptionPrompt: CFStringRef;
}

/// Reports whether this process may control the computer (post key events).
/// With `prompt` set, macOS shows the one-time Accessibility approval dialog.
pub fn accessibility_trusted(prompt: bool) -> bool {
    unsafe {
        let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
        let options = CFDictionary::from_CFType_pairs(&[(
            key.as_CFType(),
            CFBoolean::from(prompt).as_CFType(),
        )]);
        AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef())
    }
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceFlagsState(state_id: CGEventSourceStateID) -> u64;
    fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);
}

/// Modifiers that, still physically held, would merge into a synthesized
/// keystroke (⌘V + a held ⇧ is ⌘⇧V, which most apps do not treat as paste).
const HELD_MODIFIERS: CGEventFlags = CGEventFlags::CGEventFlagCommand
    .union(CGEventFlags::CGEventFlagShift)
    .union(CGEventFlags::CGEventFlagAlternate)
    .union(CGEventFlags::CGEventFlagControl)
    .union(CGEventFlags::CGEventFlagSecondaryFn);

/// Waits for the user to let go of every modifier before a synthesized
/// keystroke. Push-to-talk stops when the chord's key lifts (the "1" of
/// ⌘⇧1) while its modifiers may still be down, and a streamed transcript is
/// ready within milliseconds of that — well before the fingers leave ⌘⇧.
pub fn wait_for_modifier_release(timeout: Duration) -> Result<(), String> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        let flags = CGEventFlags::from_bits_truncate(unsafe {
            CGEventSourceFlagsState(CGEventSourceStateID::HIDSystemState)
        });
        if !flags.intersects(HELD_MODIFIERS) {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err("modifier keys were still held, so the paste keystroke was not sent".into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// Pastes the current clipboard into the focused app by synthesizing ⌘V.
/// The transcript is already on the clipboard, so this delivers it at the
/// cursor without disturbing the copied-messages flow.
pub fn paste_clipboard_at_cursor() -> Result<(), String> {
    if !accessibility_trusted(true) {
        return Err(
            "Bark needs the macOS Accessibility permission to insert text at the cursor"
                .to_string(),
        );
    }

    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "Could not create a keyboard event source".to_string())?;

    let key_down = CGEvent::new_keyboard_event(source.clone(), KEY_CODE_V, true)
        .map_err(|_| "Could not create the paste key-down event".to_string())?;
    key_down.set_flags(CGEventFlags::CGEventFlagCommand);
    let key_up = CGEvent::new_keyboard_event(source, KEY_CODE_V, false)
        .map_err(|_| "Could not create the paste key-up event".to_string())?;
    key_up.set_flags(CGEventFlags::CGEventFlagCommand);

    key_down.post(CGEventTapLocation::HID);
    // Give the focused app one frame to observe the key-down before release;
    // some apps drop instantaneous synthetic presses.
    thread::sleep(Duration::from_millis(12));
    key_up.post(CGEventTapLocation::HID);
    Ok(())
}

/// The app the user is dictating into, captured at finish time so the AI
/// polish pass can match its register (and skip terminals).
#[derive(Clone, Debug)]
pub struct FrontmostApp {
    pub bundle_id: String,
    pub name: String,
}

/// Identity of the frontmost application via NSWorkspace. Needs no macOS
/// permission. Returns None when there is no frontmost app or it exposes no
/// bundle identifier (e.g. some daemon-owned windows).
pub fn frontmost_app() -> Option<FrontmostApp> {
    let workspace = objc2_app_kit::NSWorkspace::sharedWorkspace();
    let app = workspace.frontmostApplication()?;
    let bundle_id = app.bundleIdentifier()?.to_string();
    let name = app
        .localizedName()
        .map(|name| name.to_string())
        .unwrap_or_default();
    Some(FrontmostApp { bundle_id, name })
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct FnPushToTalkEvent {
    pressed: bool,
}

/// How often a held Fn is checked against the keyboard's live state, in case
/// its release never reaches the tap.
const FN_RELEASE_POLL: Duration = Duration::from_millis(150);

/// Whether Fn/Globe is down right now, from the keyboard's live state. Needs
/// no permission beyond the tap's own.
fn fn_key_down_now() -> bool {
    CGEventFlags::from_bits_truncate(unsafe {
        CGEventSourceFlagsState(CGEventSourceStateID::CombinedSessionState)
    })
    .contains(CGEventFlags::CGEventFlagSecondaryFn)
}

/// The tap's view of the Fn key, and the rules for when a release that never
/// arrived must be made up so a hold-to-talk recording still ends.
#[derive(Default)]
struct FnHold {
    down: AtomicBool,
    /// The live keyboard state has reported Fn down during this hold, so it
    /// can be trusted to report the release too. Some keyboards may never
    /// report Fn there; polling them must not end a hold early.
    seen_down_live: AtomicBool,
}

impl FnHold {
    /// A `flagsChanged` event for Fn. Returns the change to emit, if any.
    fn on_event(&self, pressed: bool) -> Option<bool> {
        if pressed {
            self.seen_down_live.store(false, Ordering::SeqCst);
        }
        let was_down = self.down.swap(pressed, Ordering::SeqCst);
        (pressed != was_down).then_some(pressed)
    }

    /// The tap was re-enabled after macOS disabled it, so events may have
    /// been missed. Returns `true` when a release must be synthesised: Fn was
    /// held and the live state says it is up now.
    fn on_tap_reenabled(&self, down_now: bool) -> bool {
        !down_now && self.take_release()
    }

    /// A poll of the live state while Fn is held. Returns `true` when a
    /// release must be synthesised.
    fn on_poll(&self, down_now: bool) -> bool {
        if down_now {
            self.seen_down_live.store(true, Ordering::SeqCst);
            return false;
        }
        self.seen_down_live.load(Ordering::SeqCst) && self.take_release()
    }

    fn is_down(&self) -> bool {
        self.down.load(Ordering::SeqCst)
    }

    /// Marks Fn released, once: `true` only for the caller that did it.
    fn take_release(&self) -> bool {
        self.down
            .compare_exchange(true, false, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
    }
}

fn emit_fn(app: &AppHandle, enabled: &AtomicBool, pressed: bool) {
    if enabled.load(Ordering::SeqCst) {
        let _ = app.emit("fn-push-to-talk", FnPushToTalkEvent { pressed });
    }
}

/// While Fn is held, watches the live keyboard state and synthesises the
/// release if it never reaches the tap.
fn spawn_fn_release_poll(app: AppHandle, enabled: Arc<AtomicBool>, hold: Arc<FnHold>) {
    thread::Builder::new()
        .name("fn-release-poll".to_string())
        .spawn(move || {
            while hold.is_down() {
                thread::sleep(FN_RELEASE_POLL);
                if hold.on_poll(fn_key_down_now()) {
                    crate::emit_backend_event(
                        &app,
                        "warning",
                        "Fn was released without the release reaching Bark; ending the hold",
                    );
                    emit_fn(&app, &enabled, false);
                }
            }
        })
        .ok();
}

/// Spawns the listen-only event tap that watches the Fn/Globe modifier and
/// emits `fn-push-to-talk` to the pill window on press and release. The tap
/// stays installed for the app lifetime; `enabled` gates emission so settings
/// changes apply without reinstalling (and re-prompting for) the tap.
///
/// macOS disables a tap that is slow to answer or interrupted by secure
/// input. It is re-enabled straight away, and since a release may have been
/// missed meanwhile, Fn is checked against the live keyboard state then and,
/// while held, every `FN_RELEASE_POLL`: a hold-to-talk recording must end
/// when the key comes up, whatever happened to the event.
pub fn spawn_fn_push_to_talk_tap(app: AppHandle, enabled: Arc<AtomicBool>) {
    thread::Builder::new()
        .name("fn-push-to-talk-tap".to_string())
        .spawn(move || {
            let hold = Arc::new(FnHold::default());
            // The tap's own port, for re-enabling it from its callback.
            let port = Arc::new(AtomicPtr::<c_void>::new(std::ptr::null_mut()));
            let emit_app = app.clone();
            let callback_enabled = enabled.clone();
            let callback_port = port.clone();
            let tap = CGEventTap::new(
                CGEventTapLocation::HID,
                CGEventTapPlacement::HeadInsertEventTap,
                CGEventTapOptions::ListenOnly,
                vec![CGEventType::FlagsChanged],
                move |_proxy, event_type, event| {
                    match event_type {
                        CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput => {
                            let tap_port = callback_port.load(Ordering::SeqCst);
                            if !tap_port.is_null() {
                                unsafe { CGEventTapEnable(tap_port as CFMachPortRef, true) };
                            }
                            let missed_release = hold.on_tap_reenabled(fn_key_down_now());
                            crate::emit_backend_event(
                                &emit_app,
                                "warning",
                                if missed_release {
                                    "macOS paused the Fn key listener; re-enabled it and ended the hold, as Fn is up"
                                } else {
                                    "macOS paused the Fn key listener; re-enabled it"
                                },
                            );
                            if missed_release {
                                emit_fn(&emit_app, &callback_enabled, false);
                            }
                        }
                        CGEventType::FlagsChanged
                            if event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE)
                                == KEY_CODE_FN =>
                        {
                            let pressed = event
                                .get_flags()
                                .contains(CGEventFlags::CGEventFlagSecondaryFn);
                            if let Some(pressed) = hold.on_event(pressed) {
                                emit_fn(&emit_app, &callback_enabled, pressed);
                                if pressed {
                                    spawn_fn_release_poll(
                                        emit_app.clone(),
                                        callback_enabled.clone(),
                                        hold.clone(),
                                    );
                                }
                            }
                        }
                        _ => {}
                    }
                    CallbackResult::Keep
                },
            );
            let Ok(tap) = tap else {
                crate::emit_backend_event(
                    &app,
                    "warning",
                    "Hold-Fn push-to-talk is unavailable: macOS denied the keyboard event tap. \
                     Grant Bark the Input Monitoring (or Accessibility) permission and relaunch.",
                );
                return;
            };
            port.store(
                tap.mach_port().as_concrete_TypeRef() as *mut c_void,
                Ordering::SeqCst,
            );
            let Ok(source) = tap.mach_port().create_runloop_source(0) else {
                crate::emit_backend_event(
                    &app,
                    "warning",
                    "Hold-Fn push-to-talk is unavailable: its event tap could not join the run loop",
                );
                return;
            };
            CFRunLoop::get_current().add_source(&source, unsafe { kCFRunLoopCommonModes });
            tap.enable();
            CFRunLoop::run_current();
        })
        .ok();
}

#[cfg(test)]
mod tests {
    use super::FnHold;

    #[test]
    fn press_and_release_are_emitted_once_each() {
        let hold = FnHold::default();
        assert_eq!(hold.on_event(true), Some(true));
        assert_eq!(hold.on_event(true), None);
        assert_eq!(hold.on_event(false), Some(false));
        assert_eq!(hold.on_event(false), None);
    }

    #[test]
    fn a_release_missed_while_the_tap_was_disabled_is_synthesised() {
        let hold = FnHold::default();
        hold.on_event(true);
        // Still held when the tap comes back: nothing to do.
        assert!(!hold.on_tap_reenabled(true));
        assert!(hold.is_down());
        // Released while it was off: the release is made up, once.
        assert!(hold.on_tap_reenabled(false));
        assert!(!hold.on_tap_reenabled(false));
        // The real release, if it arrives after all, is not emitted twice.
        assert_eq!(hold.on_event(false), None);
    }

    #[test]
    fn re_enabling_with_fn_up_and_no_hold_emits_nothing() {
        let hold = FnHold::default();
        assert!(!hold.on_tap_reenabled(false));
    }

    #[test]
    fn polling_only_ends_a_hold_once_the_live_state_has_shown_fn_down() {
        let hold = FnHold::default();
        hold.on_event(true);
        // A keyboard whose live state never reports Fn: the hold is kept.
        assert!(!hold.on_poll(false));
        assert!(hold.is_down());
        // Once the live state has shown it held, its release counts.
        assert!(!hold.on_poll(true));
        assert!(hold.on_poll(false));
        assert!(!hold.is_down());
        assert_eq!(hold.on_event(false), None);
    }

    #[test]
    fn a_new_press_forgets_the_last_hold_s_live_state() {
        let hold = FnHold::default();
        hold.on_event(true);
        hold.on_poll(true);
        hold.on_event(false);
        hold.on_event(true);
        assert!(!hold.on_poll(false));
        assert!(hold.is_down());
    }
}
