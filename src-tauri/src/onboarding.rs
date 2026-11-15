//! First-run onboarding: whether it has been completed, the privacy
//! permissions it walks through, and its window.
//!
//! The flow itself is the `onboarding` window (onboarding.html). It opens in
//! place of the home window until the person finishes or skips it, and
//! Settings can open it again. Completion is one small JSON file in the
//! config directory, apart from settings.json so neither can overwrite the
//! other.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager};

pub const WINDOW_LABEL: &str = "onboarding";

/// Set when the person closes onboarding before finishing: "later" lasts
/// until the app restarts, so reopening the app meanwhile shows Home.
static DEFERRED: AtomicBool = AtomicBool::new(false);

/// Closing the window before the end defers onboarding to the next start.
pub fn defer_for_session() {
    DEFERRED.store(true, Ordering::SeqCst);
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Stored {
    #[serde(default)]
    completed: bool,
}

fn state_path() -> PathBuf {
    if let Some(path) = crate::app_dirs::env_var_os("FAIRSPOKEN_ONBOARDING_PATH") {
        return PathBuf::from(path);
    }
    crate::app_dirs::config_dir()
        .map(|dir| dir.join("onboarding.json"))
        .unwrap_or_else(|| PathBuf::from("onboarding.json"))
}

fn read_stored(path: &std::path::Path) -> Stored {
    crate::app_dirs::read_json_or_back_up::<Stored>(path).unwrap_or_default()
}

fn write_stored(path: &std::path::Path, stored: Stored) -> Result<(), String> {
    let bytes = serde_json::to_vec(&stored).map_err(|err| err.to_string())?;
    crate::app_dirs::write_atomic(path, &bytes)
        .map_err(|err| format!("Could not save onboarding state: {err}"))
}

/// Whether the first-run flow should open at startup.
pub fn needs_onboarding() -> bool {
    !read_stored(&state_path()).completed
}

/// "macos", "windows" or "linux": which permission steps the flow shows.
pub fn platform() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "linux"
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OnboardingState {
    completed: bool,
    platform: &'static str,
}

#[tauri::command]
pub fn get_onboarding_state() -> OnboardingState {
    OnboardingState {
        completed: !needs_onboarding(),
        platform: platform(),
    }
}

/// Records that onboarding is done, closes its window and opens Home.
#[tauri::command]
pub fn complete_onboarding(app: AppHandle) -> Result<(), String> {
    write_stored(&state_path(), Stored { completed: true })?;
    if let Some(window) = app.get_webview_window(WINDOW_LABEL) {
        let _ = window.hide();
    }
    crate::open_home_window(app, None)
}

/// The window to show when the app starts or is reopened: onboarding until it
/// is done, then Home.
pub fn open_start_window(app: &AppHandle) {
    if needs_onboarding()
        && !DEFERRED.load(Ordering::SeqCst)
        && open_onboarding_window(app.clone()).is_ok()
    {
        return;
    }
    let _ = crate::open_home_window(app.clone(), None);
}

/// Shows the onboarding window (first run, or Settings → General).
#[tauri::command]
pub fn open_onboarding_window(app: AppHandle) -> Result<(), String> {
    let window = app
        .get_webview_window(WINDOW_LABEL)
        .ok_or_else(|| "Onboarding window is not configured".to_string())?;
    let _ = window.center();
    window.show().map_err(|err| err.to_string())?;
    let _ = window.unminimize();
    window.set_focus().map_err(|err| err.to_string())
}

/// One permission's state, as the onboarding cards show it. Each platform
/// reports only some of these, hence the allow.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Permission {
    Granted,
    Denied,
    /// Not asked yet: asking shows the system prompt.
    NotDetermined,
    /// This platform does not gate it, or cannot say (the window's own
    /// microphone check answers instead).
    Unknown,
    NotNeeded,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionStatus {
    platform: &'static str,
    microphone: Permission,
    accessibility: Permission,
    input_monitoring: Permission,
}

#[tauri::command]
pub fn get_permission_status() -> PermissionStatus {
    PermissionStatus {
        platform: platform(),
        microphone: system::microphone(),
        accessibility: system::accessibility(),
        input_monitoring: system::input_monitoring(),
    }
}

/// Asks for one permission. Where the system has a prompt that has not been
/// shown yet, this shows it; once a person has answered, macOS never asks
/// again, so this opens the matching pane of System Settings instead.
#[tauri::command]
pub fn request_permission(kind: String) -> Result<PermissionStatus, String> {
    match kind.as_str() {
        "microphone" => system::request_microphone(),
        "accessibility" => system::request_accessibility(),
        "inputMonitoring" => system::request_input_monitoring(),
        other => return Err(format!("Unknown permission: {other}")),
    }
    Ok(get_permission_status())
}

#[cfg(target_os = "macos")]
mod system {
    use super::Permission;
    use objc2::{class, msg_send};
    use objc2_foundation::NSString;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// macOS shows the Accessibility dialog once; a second Allow this session
    /// goes to the pane instead of asking again behind it.
    static ACCESSIBILITY_ASKED: AtomicBool = AtomicBool::new(false);

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {
        static AVMediaTypeAudio: &'static NSString;
    }

    #[link(name = "IOKit", kind = "framework")]
    extern "C" {
        fn IOHIDCheckAccess(request: u32) -> u32;
        fn IOHIDRequestAccess(request: u32) -> bool;
    }

    /// kIOHIDRequestTypeListenEvent: Input Monitoring.
    const LISTEN_EVENT: u32 = 1;

    fn open_privacy_pane(anchor: &str) {
        let _ = std::process::Command::new("open")
            .arg(format!(
                "x-apple.systempreferences:com.apple.preference.security?{anchor}"
            ))
            .spawn();
    }

    pub fn microphone() -> Permission {
        // AVAuthorizationStatus: 0 not determined, 1 restricted, 2 denied, 3 authorized.
        let status: isize = unsafe {
            msg_send![class!(AVCaptureDevice), authorizationStatusForMediaType: AVMediaTypeAudio]
        };
        match status {
            3 => Permission::Granted,
            0 => Permission::NotDetermined,
            _ => Permission::Denied,
        }
    }

    pub fn accessibility() -> Permission {
        if crate::macos_input::accessibility_trusted(false) {
            Permission::Granted
        } else {
            Permission::Denied
        }
    }

    pub fn input_monitoring() -> Permission {
        // IOHIDAccessType: 0 granted, 1 denied, 2 unknown (not asked yet).
        match unsafe { IOHIDCheckAccess(LISTEN_EVENT) } {
            0 => Permission::Granted,
            1 => Permission::Denied,
            _ => Permission::NotDetermined,
        }
    }

    /// The first ask is the window's own getUserMedia, which shows the
    /// system prompt; this only sends a person who said no to the pane.
    pub fn request_microphone() {
        if microphone() == Permission::Denied {
            open_privacy_pane("Privacy_Microphone");
        }
    }

    pub fn request_accessibility() {
        if crate::macos_input::accessibility_trusted(false) {
            return;
        }
        if ACCESSIBILITY_ASKED.swap(true, Ordering::SeqCst) {
            open_privacy_pane("Privacy_Accessibility");
        } else {
            // Shows the system dialog, which itself offers System Settings.
            crate::macos_input::accessibility_trusted(true);
        }
    }

    pub fn request_input_monitoring() {
        match input_monitoring() {
            Permission::NotDetermined => {
                unsafe { IOHIDRequestAccess(LISTEN_EVENT) };
            }
            Permission::Denied => open_privacy_pane("Privacy_ListenEvent"),
            _ => {}
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod system {
    use super::Permission;

    // Windows and Linux gate none of these the way macOS does. The window
    // checks the microphone itself (opening it is the test), so the answer
    // here is "unknown" rather than a guess.
    pub fn microphone() -> Permission {
        Permission::Unknown
    }
    pub fn accessibility() -> Permission {
        Permission::NotNeeded
    }
    pub fn input_monitoring() -> Permission {
        Permission::NotNeeded
    }
    pub fn request_microphone() {}
    pub fn request_accessibility() {}
    pub fn request_input_monitoring() {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completion_round_trips_and_defaults_to_not_done() {
        let dir = std::env::temp_dir().join(format!("fairspoken-onboarding-{}", std::process::id()));
        let path = dir.join("onboarding.json");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!read_stored(&path).completed, "missing file means not done");
        write_stored(&path, Stored { completed: true }).unwrap();
        assert!(read_stored(&path).completed);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn permission_states_serialize_as_the_window_reads_them() {
        let status = PermissionStatus {
            platform: "macos",
            microphone: Permission::NotDetermined,
            accessibility: Permission::Granted,
            input_monitoring: Permission::NotNeeded,
        };
        assert_eq!(
            serde_json::to_value(status).unwrap(),
            serde_json::json!({
                "platform": "macos",
                "microphone": "not-determined",
                "accessibility": "granted",
                "inputMonitoring": "not-needed",
            })
        );
    }
}
