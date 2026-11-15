//! Opt-in training-data capture ("Keep my dictations to improve models"),
//! off by default. Each dictation keeps its audio and every stage of its
//! text on this device, so it can later be exported to fine-tune a speech
//! model or train a polish LoRA. Nothing here is ever uploaded.
//!
//! Layout, under the app data dir (`FAIRSPOKEN_TRAINING_DATA_DIR` overrides):
//!
//! ```text
//! training-data/
//!   index.jsonl          one CaptureEntry per line
//!   <id>/audio.wav       16 kHz mono 16-bit PCM
//!   <id>/meta.json       the same CaptureEntry
//! ```
//!
//! Only the app category is kept about the target app, never its name or
//! window contents. The export format is documented in docs/training-data.md.
//!
//! Kept dictations are hard to replace, so nothing here removes more than it
//! must: retention is off unless the user picks it, runs only while capture
//! is on, and only removes entries this app wrote (`RECORDED_BY`); "Delete
//! all" removes only the folders the index names; ids are checked before
//! they become paths; and a rewritten index keeps every line it could not
//! read, byte for byte.
//!
//! The macOS app can share the folder, so both hold an advisory lock on
//! `.index.lock` (flock on Unix) around anything that reads and then writes
//! the index. The index itself is never locked: rewrites replace it.

use crate::audio::Recording;
use crate::settings::Settings;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{ErrorKind, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

const SAMPLE_RATE: u32 = 16_000;
const INDEX_FILE: &str = "index.jsonl";
const AUDIO_FILE: &str = "audio.wav";
const META_FILE: &str = "meta.json";
/// Advisory lock shared with the macOS app (`TrainingDataStore.lockFile`).
const LOCK_FILE: &str = ".index.lock";
/// How long to wait for the other app to finish with the index.
const LOCK_WAIT: Duration = Duration::from_secs(2);
const BUSY: &str = "The training-data folder is busy; try again";
const SECONDS_PER_DAY: u64 = 24 * 60 * 60;
/// `recordedBy` of every entry this app writes. Retention only removes
/// entries that carry it, so a folder shared with the macOS app (which does
/// not write it), or entries from builds before it, are never pruned.
const RECORDED_BY: &str = "fairspoken-desktop";

/// One kept dictation.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureEntry {
    pub id: String,
    /// Epoch seconds.
    pub created_at: u64,
    pub duration_seconds: f32,
    /// `Settings::speech_model_id`.
    pub speech_model: String,
    /// `AppCategory::id` of the app dictated into.
    pub app_category: String,
    /// The speech model's text.
    pub raw_text: String,
    /// The polish model's text, when polish changed anything.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub polished_text: Option<String>,
    /// What was inserted, after corrections and snippets.
    pub final_text: String,
    /// The dictation as the user left it, when the edit watcher saw a change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edited_text: Option<String>,
    /// `RECORDED_BY` for entries this app wrote; absent otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded_by: Option<String>,
}

/// One line of index.jsonl. A line this build cannot read (damaged, from a
/// newer format, or naming an unsafe id) is never touched and is written
/// back exactly as it was.
enum IndexLine {
    Entry(CaptureEntry),
    Unreadable(Vec<u8>),
}

/// An id names a folder under the root, so it must be one plain path
/// component: not empty, no separators, no `..`, not absolute.
fn is_safe_id(id: &str) -> bool {
    let mut components = Path::new(id).components();
    !id.contains("..")
        && !id.contains(['/', '\\', ':', '\0'])
        && matches!(components.next(), Some(Component::Normal(_)))
        && components.next().is_none()
}

/// Days of retention to apply now: none unless capture is on.
fn retention_for(settings: &Settings) -> u16 {
    if settings.training_capture {
        settings.training_keep_days
    } else {
        0
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSummary {
    pub count: usize,
    pub bytes: u64,
}

/// The texts of one dictation, borrowed from the commit path.
pub struct DictationTexts<'a> {
    pub raw: &'a str,
    pub polished: Option<&'a str>,
    pub final_text: &'a str,
}

pub struct CaptureStore {
    root: PathBuf,
}

impl CaptureStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    fn index_path(&self) -> PathBuf {
        self.root.join(INDEX_FILE)
    }

    /// Takes the lock shared with the macOS app, waiting up to `LOCK_WAIT`.
    /// `None` when it is still held, or the root is missing. Released when the
    /// returned file is dropped.
    fn lock_index(&self) -> Option<fs::File> {
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        private_mode(&mut options);
        let file = options.open(self.root.join(LOCK_FILE)).ok()?;
        let deadline = Instant::now() + LOCK_WAIT;
        loop {
            match file.try_lock() {
                Ok(()) => return Some(file),
                Err(fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(25))
                }
                Err(_) => return None,
            }
        }
    }

    /// Writes the dictation's folder, then appends it to the index.
    pub fn record(&self, entry: &CaptureEntry, samples: &[i16]) -> Result<(), String> {
        if !is_safe_id(&entry.id) {
            return Err(format!("Refusing to keep a dictation with id {:?}", entry.id));
        }
        // The root first, so `create_dir_all` never leaves it world-readable;
        // this also tightens a root an older build created 0755.
        create_private_dir(&self.root)
            .map_err(|err| format!("Could not create {:?}: {err}", self.root))?;
        let folder = self.root.join(&entry.id);
        create_private_dir(&folder).map_err(|err| format!("Could not create {folder:?}: {err}"))?;
        write_wav(&folder.join(AUDIO_FILE), samples)?;
        write_json(&folder.join(META_FILE), entry)?;
        let mut line = serde_json::to_vec(entry).map_err(|err| err.to_string())?;
        line.push(b'\n');
        // Wait for the other app to finish rewriting the index, but append
        // even if it doesn't let go: a recording is never dropped.
        let _lock = self.lock_index();
        let mut options = fs::OpenOptions::new();
        options.create(true).read(true).append(true);
        private_mode(&mut options);
        options
            .open(self.index_path())
            .and_then(|mut index| {
                // `mode` only applies on creation; tighten an older 0644 index.
                restrict_to_owner(&index)?;
                // A last line without its newline would swallow this one.
                if !ends_with_newline(&mut index)? {
                    line.insert(0, b'\n');
                }
                index.write_all(&line)
            })
            .map_err(|err| format!("Could not update the training-data index: {err}"))
    }

    /// Every readable entry; a damaged line is skipped, not fatal.
    pub fn entries(&self) -> Vec<CaptureEntry> {
        self.read_index()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|line| match line {
                IndexLine::Entry(entry) => Some(entry),
                IndexLine::Unreadable(_) => None,
            })
            .collect()
    }

    /// Every line of the index. A missing index is empty; one that exists but
    /// cannot be read is an error, so it is never rewritten from nothing.
    fn read_index(&self) -> Result<Vec<IndexLine>, String> {
        let bytes = match fs::read(self.index_path()) {
            Ok(bytes) => bytes,
            Err(err) if err.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(err) => return Err(format!("Could not read the training-data index: {err}")),
        };
        Ok(bytes
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.iter().all(u8::is_ascii_whitespace))
            .map(|line| match serde_json::from_slice::<CaptureEntry>(line) {
                Ok(entry) if is_safe_id(&entry.id) => IndexLine::Entry(entry),
                _ => IndexLine::Unreadable(line.to_vec()),
            })
            .collect())
    }

    /// Replaces the index atomically (a temporary file, then a rename).
    fn write_index(&self, lines: &[IndexLine]) -> Result<(), String> {
        let mut payload = Vec::new();
        for line in lines {
            match line {
                IndexLine::Entry(entry) => {
                    payload.extend(serde_json::to_vec(entry).map_err(|err| err.to_string())?)
                }
                IndexLine::Unreadable(bytes) => payload.extend_from_slice(bytes),
            }
            payload.push(b'\n');
        }
        replace_private(&self.index_path(), &payload)
            .map_err(|err| format!("Could not rewrite the training-data index: {err}"))
    }

    /// Removes one entry's folder. Only ever called with a checked id.
    fn remove_entry_folder(&self, id: &str) -> Result<(), String> {
        if !is_safe_id(id) {
            return Err(format!("Refusing to delete an entry with id {id:?}"));
        }
        let folder = self.root.join(id);
        match fs::remove_dir_all(&folder) {
            Err(err) if err.kind() != ErrorKind::NotFound => Err(format!("Could not delete {folder:?}: {err}")),
            _ => Ok(()),
        }
    }

    /// Records the user's edited text for a kept dictation.
    pub fn attach_edit(&self, id: &str, edited: &str) -> Result<bool, String> {
        if !is_safe_id(id) {
            return Ok(false);
        }
        let _lock = self.lock_index().ok_or(BUSY)?;
        let mut lines = self.read_index()?;
        let Some(entry) = lines.iter_mut().find_map(|line| match line {
            IndexLine::Entry(entry) if entry.id == id => Some(entry),
            _ => None,
        }) else {
            return Ok(false);
        };
        if entry.final_text.trim() == edited.trim() {
            return Ok(false);
        }
        entry.edited_text = Some(edited.trim().to_string());
        write_json(&self.root.join(id).join(META_FILE), &*entry)?;
        self.write_index(&lines)?;
        Ok(true)
    }

    /// Deletes this app's own dictations (`RECORDED_BY`) older than
    /// `retention_days`; 0 keeps everything. Entries without the marker are
    /// never pruned. Callers pass `retention_for(settings)`, which is 0 while
    /// capture is off.
    pub fn prune(&self, retention_days: u16, now: u64) -> Result<usize, String> {
        if retention_days == 0 {
            return Ok(0);
        }
        // Pruning can wait for the next sweep.
        let Some(_lock) = self.lock_index() else {
            return Ok(0);
        };
        let cutoff = now.saturating_sub(u64::from(retention_days) * SECONDS_PER_DAY);
        let mut lines = self.read_index()?;
        let mut removed = 0;
        let mut failure = None;
        lines.retain(|line| match line {
            IndexLine::Entry(entry)
                if failure.is_none()
                    && entry.created_at < cutoff
                    && entry.recorded_by.as_deref() == Some(RECORDED_BY) =>
            {
                match self.remove_entry_folder(&entry.id) {
                    Ok(()) => {
                        removed += 1;
                        false
                    }
                    Err(err) => {
                        failure = Some(err);
                        true
                    }
                }
            }
            _ => true,
        });
        if removed > 0 {
            self.write_index(&lines)?;
        }
        failure.map_or(Ok(removed), Err)
    }

    /// Applies the user's retention choice, which is none while capture is off.
    pub fn apply_retention(&self, settings: &Settings, now: u64) -> Result<usize, String> {
        self.prune(retention_for(settings), now)
    }

    /// Deletes every kept dictation, and only those: the folders the index
    /// names, then their index lines. Anything else under the root, and
    /// index lines this build cannot read, stay where they are.
    pub fn delete_all(&self) -> Result<(), String> {
        if !self.root.is_dir() {
            return Ok(());
        }
        let _lock = self.lock_index().ok_or(BUSY)?;
        let mut lines = self.read_index()?;
        let mut failure = None;
        lines.retain(|line| match line {
            IndexLine::Entry(entry) if failure.is_none() => match self.remove_entry_folder(&entry.id) {
                Ok(()) => false,
                Err(err) => {
                    failure = Some(err);
                    true
                }
            },
            _ => true,
        });
        if lines.is_empty() {
            match fs::remove_file(self.index_path()) {
                Err(err) if err.kind() != ErrorKind::NotFound => {
                    return Err(format!("Could not delete the training-data index: {err}"))
                }
                _ => {}
            }
        } else {
            self.write_index(&lines)?;
        }
        failure.map_or(Ok(()), Err)
    }

    pub fn summary(&self) -> CaptureSummary {
        CaptureSummary {
            count: self.entries().len(),
            bytes: directory_size(&self.root),
        }
    }

    /// Writes the export zip (see docs/training-data.md) and returns how many
    /// dictations it holds.
    pub fn export(&self, destination: &Path) -> Result<usize, String> {
        use zip::write::SimpleFileOptions;
        let entries: Vec<CaptureEntry> = self
            .entries()
            .into_iter()
            .filter(|entry| self.root.join(&entry.id).join(AUDIO_FILE).is_file())
            .collect();
        let file = fs::File::create(destination)
            .map_err(|err| format!("Could not create {destination:?}: {err}"))?;
        let mut zip = zip::ZipWriter::new(file);
        let text = SimpleFileOptions::default();
        // WAV barely compresses; storing it keeps exports fast.
        let audio = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        let fail = |err: &dyn std::fmt::Display| format!("Could not write the export: {err}");

        let mut manifest = String::new();
        let mut polish = String::new();
        for entry in &entries {
            let target = entry.edited_text.as_deref().unwrap_or(&entry.final_text);
            let audio_path = format!("audio/{}.wav", entry.id);
            manifest.push_str(
                &serde_json::json!({
                    "audio_filepath": audio_path,
                    "duration": entry.duration_seconds,
                    "text": target,
                    "id": entry.id,
                    "created_at": entry.created_at,
                    "speech_model": entry.speech_model,
                    "app_category": entry.app_category,
                    "raw_text": entry.raw_text,
                    "polished_text": entry.polished_text,
                    "final_text": entry.final_text,
                    "edited_text": entry.edited_text,
                })
                .to_string(),
            );
            manifest.push('\n');
            polish.push_str(
                &serde_json::json!({ "id": entry.id, "prompt": entry.raw_text, "completion": target })
                    .to_string(),
            );
            polish.push('\n');

            zip.start_file(audio_path, audio).map_err(|err| fail(&err))?;
            let bytes = fs::read(self.root.join(&entry.id).join(AUDIO_FILE)).map_err(|err| fail(&err))?;
            zip.write_all(&bytes).map_err(|err| fail(&err))?;
        }
        for (name, contents) in [
            ("manifest.jsonl", manifest.as_str()),
            ("polish.jsonl", polish.as_str()),
            ("README.txt", EXPORT_README),
        ] {
            zip.start_file(name, text).map_err(|err| fail(&err))?;
            zip.write_all(contents.as_bytes()).map_err(|err| fail(&err))?;
        }
        zip.finish().map_err(|err| fail(&err))?;
        Ok(entries.len())
    }
}

const EXPORT_README: &str = "Fairspoken training data export (format version 1).\n\
\n\
manifest.jsonl  one dictation per line, NeMo-style: audio_filepath, duration, text\n\
                (the user's edited text, else the inserted text), plus every\n\
                stage of the text and the speech model that heard it.\n\
polish.jsonl    prompt/completion pairs (speech model text -> final text) for\n\
                polish LoRA training with MLX-LM.\n\
audio/          16 kHz mono 16-bit PCM WAV, one per dictation.\n\
\n\
These recordings may contain sensitive or patient information. Keep them on\n\
machines you control. See docs/training-data.md in the Fairspoken repository.\n";

fn create_private_dir(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn write_wav(path: &Path, samples: &[i16]) -> Result<(), String> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer =
        hound::WavWriter::create(path, spec).map_err(|err| format!("Could not write audio: {err}"))?;
    for sample in samples {
        writer
            .write_sample(*sample)
            .map_err(|err| format!("Could not write audio: {err}"))?;
    }
    writer
        .finalize()
        .map_err(|err| format!("Could not write audio: {err}"))
}

/// Written beside, then renamed over, so a crash never leaves a half-written meta.json.
fn write_json(path: &Path, entry: &CaptureEntry) -> Result<(), String> {
    let payload = serde_json::to_string_pretty(entry).map_err(|err| err.to_string())?;
    replace_private(path, payload.as_bytes()).map_err(|err| format!("Could not write {path:?}: {err}"))
}

/// Replaces `path` atomically with an owner-only file: a temporary file in
/// the same folder, then a rename over it.
fn replace_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("file");
    let temporary = path.with_file_name(format!(".{name}.{}.tmp", uuid::Uuid::new_v4()));
    write_private(&temporary, bytes)
        .and_then(|_| fs::rename(&temporary, path))
        .inspect_err(|_| {
            let _ = fs::remove_file(&temporary);
        })
}

/// Whether an index opened for reading ends with a newline (an empty one does).
fn ends_with_newline(file: &mut fs::File) -> std::io::Result<bool> {
    use std::io::{Read, Seek, SeekFrom};
    if file.metadata()?.len() == 0 {
        return Ok(true);
    }
    file.seek(SeekFrom::End(-1))?;
    let mut last = [0u8; 1];
    file.read_exact(&mut last)?;
    Ok(last[0] == b'\n')
}

/// Owner-only (0600) for newly created files: they hold the text of kept
/// dictations, which may include patient information.
fn private_mode(options: &mut fs::OpenOptions) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    #[cfg(not(unix))]
    let _ = options;
}

fn restrict_to_owner(file: &fs::File) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(not(unix))]
    let _ = file;
    Ok(())
}

/// Writes `bytes` to `path` (created or truncated) as an owner-only file.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    private_mode(&mut options);
    let mut file = options.open(path)?;
    restrict_to_owner(&file)?;
    file.write_all(bytes)
}

fn directory_size(path: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(metadata) if metadata.is_dir() => directory_size(&entry.path()),
            Ok(metadata) => metadata.len(),
            Err(_) => 0,
        })
        .sum()
}

fn to_16khz(recording: &Recording) -> Vec<i16> {
    crate::transcription::resample_i16_to_16khz_f32(&recording.pcm_i16, recording.sample_rate)
        .into_iter()
        .map(|sample| (sample * 32768.0).round().clamp(-32768.0, 32767.0) as i16)
        .collect()
}

fn default_root() -> Option<PathBuf> {
    if let Some(path) = crate::app_dirs::env_var_os("FAIRSPOKEN_TRAINING_DATA_DIR") {
        return Some(PathBuf::from(path));
    }
    crate::app_dirs::data_dir().map(|dir| dir.join("training-data"))
}

/// Serialises file access between the commit path, the edit watcher, the
/// sweeper and the Settings commands.
static LOCK: Mutex<()> = Mutex::new(());

fn with_store<R>(use_store: impl FnOnce(&CaptureStore) -> R) -> Result<R, String> {
    let root = default_root().ok_or("No data directory for training data")?;
    let _guard = LOCK.lock().map_err(|_| "Training data lock failed".to_string())?;
    Ok(use_store(&CaptureStore::new(root)))
}

fn now_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

/// Keeps this dictation when capture is on, writing it in the background.
/// Returns its id so the edit watcher can attach the user's edit later.
pub fn capture_dictation(
    app: &AppHandle,
    settings: &Settings,
    recording: &Recording,
    texts: DictationTexts<'_>,
    app_category: &str,
) -> Option<String> {
    if !settings.training_capture {
        return None;
    }
    let mut entry = CaptureEntry {
        id: uuid::Uuid::new_v4().to_string(),
        created_at: now_seconds(),
        duration_seconds: 0.0,
        speech_model: settings.speech_model_id(),
        app_category: app_category.to_string(),
        raw_text: texts.raw.to_string(),
        polished_text: texts.polished.map(str::to_string),
        final_text: texts.final_text.to_string(),
        edited_text: None,
        recorded_by: Some(RECORDED_BY.to_string()),
    };
    let id = entry.id.clone();
    let app = app.clone();
    // The copy is cheap; the resample runs on the writer thread so it never
    // delays the paste.
    let recording = recording.clone();
    let _ = std::thread::Builder::new()
        .name("training-capture".to_string())
        .spawn(move || {
            let samples = to_16khz(&recording);
            drop(recording);
            entry.duration_seconds = samples.len() as f32 / SAMPLE_RATE as f32;
            let result = with_store(|store| {
                store.record(&entry, &samples)?;
                apply_current_retention(&app, store)
            });
            if let Err(err) | Ok(Err(err)) = result {
                crate::emit_backend_event(&app, "warning", format!("Could not keep dictation: {err}"));
            }
        });
    Some(id)
}

/// Records the user's edit of a kept dictation, if it is still kept.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn attach_edit(id: &str, edited: &str) {
    let _ = with_store(|store| store.attach_edit(id, edited));
}

/// Applies the retention in the settings as they are now, read while the
/// caller holds the store lock, so turning capture off or choosing "until I
/// delete them" a moment earlier always wins. Keeps everything when the
/// settings cannot be read.
fn apply_current_retention(app: &AppHandle, store: &CaptureStore) -> Result<usize, String> {
    let Ok(settings) = app.state::<crate::AppServices>().settings.lock().map(|service| service.current()) else {
        return Ok(0);
    };
    store.apply_retention(&settings, now_seconds())
}

/// Applies a retention the user chose while capture is on, so this app's old
/// dictations go even when no new ones are kept. Does nothing otherwise.
pub fn start_retention_sweeper(app: AppHandle) {
    let _ = std::thread::Builder::new()
        .name("training-retention-sweeper".to_string())
        .spawn(move || loop {
            let _ = with_store(|store| apply_current_retention(&app, store));
            std::thread::sleep(Duration::from_secs(60 * 60));
        });
}

/// Sizes the folder off the main thread. Never deletes anything.
#[tauri::command]
pub async fn get_training_data_summary() -> Result<CaptureSummary, String> {
    tauri::async_runtime::spawn_blocking(|| with_store(CaptureStore::summary))
        .await
        .map_err(|err| err.to_string())?
}

#[tauri::command]
pub async fn delete_training_data() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(|| with_store(CaptureStore::delete_all)?)
        .await
        .map_err(|err| err.to_string())?
}

/// Exports to the Downloads folder and reveals the zip. Returns its path.
#[tauri::command]
pub async fn export_training_data() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let folder = std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join("Downloads"))
            .filter(|downloads| downloads.is_dir())
            .or_else(crate::app_dirs::data_dir)
            .ok_or("No folder to export to")?;
        let destination = folder.join(format!("fairspoken-training-data-{}.zip", now_seconds()));
        let count = with_store(|store| store.export(&destination))??;
        if count == 0 {
            let _ = fs::remove_file(&destination);
            return Err("There are no kept dictations to export".to_string());
        }
        let _ = tauri_plugin_opener::reveal_item_in_dir(&destination);
        Ok(destination.to_string_lossy().into_owned())
    })
    .await
    .map_err(|err| err.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, created_at: u64) -> CaptureEntry {
        CaptureEntry {
            id: id.to_string(),
            created_at,
            duration_seconds: 0.5,
            speech_model: "parakeet-tdt-0.6b-v3".to_string(),
            app_category: "docs".to_string(),
            raw_text: "ask cloud code".to_string(),
            polished_text: Some("Ask cloud code.".to_string()),
            final_text: "Ask cloud code.".to_string(),
            edited_text: None,
            recorded_by: Some(RECORDED_BY.to_string()),
        }
    }

    fn ids(store: &CaptureStore) -> Vec<String> {
        store.entries().into_iter().map(|entry| entry.id).collect()
    }

    fn append_to_index(root: &Path, line: &[u8]) {
        let mut index = fs::OpenOptions::new().append(true).open(root.join(INDEX_FILE)).unwrap();
        index.write_all(line).unwrap();
        index.write_all(b"\n").unwrap();
    }

    #[test]
    fn ids_are_checked_before_they_become_paths() {
        for id in ["a", "6f1c2d3e-0000-4000-8000-000000000000", "demo-0"] {
            assert!(is_safe_id(id), "{id}");
        }
        for id in ["", ".", "..", "../outside", "a/b", "a\\b", "/abs", "C:", "x..y", "a\0"] {
            assert!(!is_safe_id(id), "{id:?}");
        }

        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("training-data");
        let store = CaptureStore::new(root.clone());
        assert!(store.record(&entry("../escape", 1), &[0; 10]).is_err());
        assert!(!directory.path().join("escape").exists());
        store.record(&entry("a", 1), &[0; 10]).unwrap();
        // Lines naming the root itself, a parent folder or an absolute path.
        fs::create_dir(directory.path().join("outside")).unwrap();
        fs::write(directory.path().join("outside/keep.txt"), "keep").unwrap();
        for id in ["", "..", "../outside", directory.path().join("outside").to_str().unwrap()] {
            let line = serde_json::to_vec(&CaptureEntry { created_at: 0, ..entry(id, 0) }).unwrap();
            append_to_index(&root, &line);
        }

        assert_eq!(ids(&store), ["a"]);
        assert!(!store.attach_edit("..", "edit").unwrap());
        assert_eq!(store.prune(30, 100 * SECONDS_PER_DAY).unwrap(), 1);
        store.delete_all().unwrap();
        assert!(directory.path().join("outside/keep.txt").exists());
        assert!(root.is_dir());
        // The unsafe lines are kept as they were, not acted on.
        assert_eq!(fs::read_to_string(root.join(INDEX_FILE)).unwrap().lines().count(), 4);
    }

    #[test]
    fn rewrites_keep_unreadable_lines_byte_for_byte() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_path_buf();
        let store = CaptureStore::new(root.clone());
        store.record(&entry("a", 1), &[0; 10]).unwrap();
        let damaged: &[u8] = b"{not json";
        let not_utf8: &[u8] = b"{\"id\":\"\xff\xfe\"}";
        let newer: &[u8] = br#"{"version":2,"something":"else"}"#;
        for line in [damaged, not_utf8, newer] {
            append_to_index(&root, line);
        }
        store.record(&entry("b", 2), &[0; 10]).unwrap();

        assert!(store.attach_edit("b", "Ask Claude Code.").unwrap());
        let index = fs::read(root.join(INDEX_FILE)).unwrap();
        let lines: Vec<&[u8]> = index.split(|byte| *byte == b'\n').collect();
        assert_eq!(&lines[1..4], [damaged, not_utf8, newer]);
        assert_eq!(ids(&store), ["a", "b"]);
        assert_eq!(store.entries()[1].edited_text.as_deref(), Some("Ask Claude Code."));

        store.delete_all().unwrap();
        assert_eq!(fs::read(root.join(INDEX_FILE)).unwrap(), [damaged, not_utf8, newer, b""].join(&b'\n'));
    }

    #[test]
    fn an_index_that_cannot_be_read_is_never_rewritten() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_path_buf();
        let store = CaptureStore::new(root.clone());
        store.record(&entry("a", 1), &[0; 10]).unwrap();
        // Stand in for an unreadable index: a folder where the file should be.
        fs::rename(root.join(INDEX_FILE), root.join("saved-index")).unwrap();
        fs::create_dir(root.join(INDEX_FILE)).unwrap();

        assert!(store.attach_edit("a", "Ask Claude Code.").is_err());
        assert!(store.prune(30, 100 * SECONDS_PER_DAY).is_err());
        assert!(store.delete_all().is_err());
        assert!(root.join(INDEX_FILE).is_dir());
        assert!(root.join("a/audio.wav").exists());
    }

    #[test]
    fn delete_all_removes_only_the_entries_the_index_names() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("training-data");
        let store = CaptureStore::new(root.clone());
        store.record(&entry("a", 1), &[0; 10]).unwrap();
        store.record(&entry("b", 2), &[0; 10]).unwrap();
        fs::write(root.join("notes.txt"), "mine").unwrap();
        fs::create_dir(root.join("unlisted")).unwrap();
        fs::write(root.join("unlisted/audio.wav"), "not in the index").unwrap();
        fs::write(directory.path().join("sibling.txt"), "beside the folder").unwrap();

        store.delete_all().unwrap();

        assert!(store.entries().is_empty());
        assert!(!root.join("a").exists() && !root.join("b").exists());
        assert!(!root.join(INDEX_FILE).exists());
        assert!(root.join("notes.txt").exists());
        assert!(root.join("unlisted/audio.wav").exists());
        assert!(directory.path().join("sibling.txt").exists());
        // Deleting again, or with no index at all, is harmless.
        store.delete_all().unwrap();
        assert!(root.join("notes.txt").exists());
    }

    #[test]
    fn an_append_after_a_line_without_its_newline_starts_a_new_line() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_path_buf();
        let store = CaptureStore::new(root.clone());
        store.record(&entry("a", 1), &[0; 10]).unwrap();
        // As if a writer stopped before its newline.
        let index = fs::read(root.join(INDEX_FILE)).unwrap();
        fs::write(root.join(INDEX_FILE), &index[..index.len() - 1]).unwrap();

        store.record(&entry("b", 2), &[0; 10]).unwrap();
        assert_eq!(ids(&store), ["a", "b"]);
    }

    #[test]
    fn the_shared_lock_holds_off_rewrites_but_never_drops_a_recording() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_path_buf();
        let store = CaptureStore::new(root.clone());
        store.record(&entry("old", 1), &[0; 10]).unwrap();
        // The macOS app holding the lock.
        let held = fs::OpenOptions::new().read(true).write(true).open(root.join(LOCK_FILE)).unwrap();
        held.lock().unwrap();

        assert_eq!(store.prune(30, 100 * SECONDS_PER_DAY).unwrap(), 0);
        assert_eq!(store.delete_all().unwrap_err(), BUSY);
        assert_eq!(store.attach_edit("old", "Ask Claude Code.").unwrap_err(), BUSY);
        store.record(&entry("new", 2), &[0; 10]).unwrap();
        assert_eq!(ids(&store), ["old", "new"]);
        assert!(root.join("old/audio.wav").exists());

        held.unlock().unwrap();
        assert_eq!(store.prune(30, 100 * SECONDS_PER_DAY).unwrap(), 2);
    }

    #[test]
    fn edits_replace_meta_json_without_leaving_temporary_files() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().to_path_buf();
        let store = CaptureStore::new(root.clone());
        store.record(&entry("a", 1), &[0; 10]).unwrap();
        assert!(store.attach_edit("a", "Ask Claude Code.").unwrap());
        let mut names: Vec<String> = fs::read_dir(root.join("a"))
            .unwrap()
            .map(|item| item.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, [AUDIO_FILE, META_FILE]);
        assert!(fs::read_dir(&root).unwrap().all(|item| !item.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
    }

    #[test]
    fn retention_runs_only_while_capture_is_on_and_only_on_this_apps_entries() {
        let directory = tempfile::tempdir().unwrap();
        let store = CaptureStore::new(directory.path().to_path_buf());
        let now = 100 * SECONDS_PER_DAY;
        store.record(&entry("mine", now - 60 * SECONDS_PER_DAY), &[0; 10]).unwrap();
        // As the macOS app, or a build before the marker, writes it.
        let other = CaptureEntry { recorded_by: None, ..entry("other", now - 60 * SECONDS_PER_DAY) };
        store.record(&other, &[0; 10]).unwrap();

        let off = Settings { training_capture: false, training_keep_days: 30, ..Settings::default() };
        assert_eq!(store.apply_retention(&off, now).unwrap(), 0);
        let default = Settings { training_capture: true, ..Settings::default() };
        assert_eq!(store.apply_retention(&default, now).unwrap(), 0);
        assert_eq!(ids(&store), ["mine", "other"]);

        let chosen = Settings { training_capture: true, training_keep_days: 30, ..Settings::default() };
        assert_eq!(store.apply_retention(&chosen, now).unwrap(), 1);
        assert_eq!(ids(&store), ["other"]);
        assert!(directory.path().join("other/audio.wav").exists());
        assert!(!directory.path().join("mine").exists());
    }

    #[test]
    fn index_round_trips_and_records_edits() {
        let directory = tempfile::tempdir().unwrap();
        let store = CaptureStore::new(directory.path().join("training-data"));
        store.record(&entry("a", 100), &[0, 1000, -1000]).unwrap();
        store.record(&entry("b", 200), &[0; 8000]).unwrap();

        assert_eq!(store.entries().iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        let audio = hound::WavReader::open(directory.path().join("training-data/b/audio.wav")).unwrap();
        assert_eq!(audio.spec().sample_rate, 16_000);
        assert_eq!(audio.spec().channels, 1);
        assert_eq!(audio.len(), 8000);

        // An unchanged edit is not recorded; a real one updates index and meta.
        assert!(!store.attach_edit("a", " Ask cloud code. ").unwrap());
        assert!(store.attach_edit("a", "Ask Claude Code.").unwrap());
        assert!(!store.attach_edit("missing", "anything").unwrap());
        assert_eq!(store.entries()[0].edited_text.as_deref(), Some("Ask Claude Code."));
        let meta: CaptureEntry =
            serde_json::from_str(&fs::read_to_string(directory.path().join("training-data/a/meta.json")).unwrap())
                .unwrap();
        assert_eq!(meta.edited_text.as_deref(), Some("Ask Claude Code."));

        // A damaged line does not lose the rest of the index.
        let mut index = fs::OpenOptions::new()
            .append(true)
            .open(directory.path().join("training-data/index.jsonl"))
            .unwrap();
        index.write_all(b"{not json\n").unwrap();
        assert_eq!(store.entries().len(), 2);
        assert_eq!(store.summary().count, 2);
        assert!(store.summary().bytes > 16_000);
    }

    #[cfg(unix)]
    #[test]
    fn kept_dictations_are_readable_by_the_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("training-data");
        // An index left world-readable by an earlier build is tightened.
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(root.join(INDEX_FILE), "").unwrap();
        fs::set_permissions(root.join(INDEX_FILE), fs::Permissions::from_mode(0o644)).unwrap();
        let store = CaptureStore::new(root.clone());
        store.record(&entry("a", 100), &[0; 10]).unwrap();

        assert_eq!(mode(&root), 0o700);
        assert_eq!(mode(&root.join("a")), 0o700);
        assert_eq!(mode(&root.join(INDEX_FILE)), 0o600);
        assert_eq!(mode(&root.join("a").join(META_FILE)), 0o600);
        // A rewritten index stays private.
        assert!(store.attach_edit("a", "Ask Claude Code.").unwrap());
        assert_eq!(mode(&root.join(INDEX_FILE)), 0o600);
    }

    #[test]
    fn retention_prunes_only_expired_dictations() {
        let directory = tempfile::tempdir().unwrap();
        let store = CaptureStore::new(directory.path().to_path_buf());
        let now = 100 * SECONDS_PER_DAY;
        store.record(&entry("old", now - 31 * SECONDS_PER_DAY), &[0; 10]).unwrap();
        store.record(&entry("recent", now - 29 * SECONDS_PER_DAY), &[0; 10]).unwrap();

        assert_eq!(store.prune(0, now).unwrap(), 0);
        assert_eq!(store.entries().len(), 2);
        assert_eq!(store.prune(90, now).unwrap(), 0);
        assert_eq!(store.prune(30, now).unwrap(), 1);

        assert_eq!(store.entries().iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["recent"]);
        assert!(!directory.path().join("old").exists());
        assert!(directory.path().join("recent/audio.wav").exists());
    }

    #[test]
    fn export_writes_manifest_polish_pairs_and_audio() {
        use std::io::Read;
        let directory = tempfile::tempdir().unwrap();
        let store = CaptureStore::new(directory.path().join("data"));
        store.record(&entry("a", 1), &[0; 160]).unwrap();
        store.attach_edit("a", "Ask Claude Code.").unwrap();
        let destination = directory.path().join("export.zip");

        assert_eq!(store.export(&destination).unwrap(), 1);

        let mut zip = zip::ZipArchive::new(fs::File::open(&destination).unwrap()).unwrap();
        let mut manifest = String::new();
        zip.by_name("manifest.jsonl").unwrap().read_to_string(&mut manifest).unwrap();
        let line: serde_json::Value = serde_json::from_str(manifest.trim()).unwrap();
        assert_eq!(line["audio_filepath"], "audio/a.wav");
        assert_eq!(line["text"], "Ask Claude Code.");
        assert_eq!(line["raw_text"], "ask cloud code");
        let mut polish = String::new();
        zip.by_name("polish.jsonl").unwrap().read_to_string(&mut polish).unwrap();
        let pair: serde_json::Value = serde_json::from_str(polish.trim()).unwrap();
        assert_eq!(pair["prompt"], "ask cloud code");
        assert_eq!(pair["completion"], "Ask Claude Code.");
        assert!(zip.by_name("audio/a.wav").unwrap().size() > 44);

        store.delete_all().unwrap();
        assert_eq!(store.summary().count, 0);
        store.delete_all().unwrap();
    }

    #[test]
    fn audio_is_resampled_to_16khz() {
        let recording = Recording {
            pcm_i16: vec![1000; 48_000],
            sample_rate: 48_000,
            dropped_stream_frames: 0,
        };
        let samples = to_16khz(&recording);
        assert_eq!(samples.len(), 16_000);
        assert!(samples.iter().all(|sample| (*sample - 1000).abs() <= 1));
    }
}
