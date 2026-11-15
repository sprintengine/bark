# Training data capture and export

Fairspoken can keep your dictations so you can later fine-tune a speech
model or train a polish model on them. This is off by default. Turn it on in
**Settings → General → Training data → Keep my dictations to improve models**.

In the native macOS app it is **Post-training › Save recordings for post-training**. It
writes the same on-device layout and fields (below; `polishedText` and `editedText` are not set
yet), to `~/Library/Application Support/ie.fairspoken.mac/training-data` or a folder you choose,
for example on an external drive. Its recordings are kept until you delete them, and it has no
export yet: the folder itself is the data. Deleting a recording, or **Delete All…**, asks first and
moves the recordings to the Trash. On a drive without a Trash, nothing is deleted until you confirm
deleting permanently.

Kept dictations never leave the device unless you export them yourself. They
may contain sensitive or patient information: do not turn this on for
clinical dictation unless your practice's data protection arrangements allow
it (see "Privacy and regulation" in the model comparison spec).

## What is kept

For each dictation:

| Field | Meaning |
|---|---|
| audio | 16 kHz mono 16-bit PCM WAV of the whole recording |
| raw text | the speech model's transcript, before polish and corrections |
| polished text | the polish model's output, when polish ran and changed anything |
| final text | what was inserted, after your corrections and snippets |
| edited text | the dictation as you left it, when the edit watcher (macOS) saw you change it |
| speech model | the model id (`parakeet-tdt-0.6b-v3`, `large-v3-turbo`…), or `remote-host` / `cloud` |
| app category | `messaging`, `email`, `docs`, `code`, `terminal` or `other`; never the app's name or window contents |
| timestamp, duration | epoch seconds, and the audio length in seconds |
| recorded by | `fairspoken-desktop` on entries this app wrote (not in the export) |

## Keeping and deleting

Kept dictations stay **until you delete them** (the default). You can choose
30 or 90 days instead, under **Keep recordings**. A chosen retention only runs
while capture is on, and only removes dictations this app recorded itself
(entries with `"recordedBy": "fairspoken-desktop"`): entries from the native
macOS app, which can share the layout, and entries from builds before this
field are never removed by retention. Before this change the setting was
stored as `trainingRetentionDays` and defaulted to 30 days; that value is no
longer read, so everyone starts at "until you delete them" and picks a
retention again if they want one.

**Delete all** (asks for a second click) removes only the dictations listed in
`index.jsonl`: their `<id>/` folders, then their lines. Other files in the
folder stay, and so does the folder. In this app, deletion is permanent; the
native macOS app moves recordings to the Trash.

Both apps protect the folder the same way:

- An entry id must be a single plain name (not empty, no `/`, `\`, `:` or
  `..`) before it is used as a path; a line with any other id is ignored and
  left in the index.
- An index line that cannot be read (damaged, or from a newer version) is
  never dropped: every rewrite of `index.jsonl` keeps it byte for byte.
- An index that exists but cannot be read is never rewritten.
- Rewrites of `index.jsonl` and `meta.json` are atomic (a temporary file,
  then a rename).
- An append starts a new line if the index's last line lacks its newline.
- Both apps hold an advisory lock on `.index.lock` in the folder (`flock` on
  macOS and Linux) around every change that reads and then writes the index:
  appends, edits, deletes, retention and rebuilds. The index itself is never
  locked, since a rewrite replaces it. If the other app holds the lock for
  more than two seconds, retention waits for its next run and deletes ask you
  to try again; an append goes ahead anyway, so a recording is never lost.

The macOS app can also rebuild `index.jsonl` from each `<id>/meta.json`
(`TrainingDataStore.rebuildIndex()`), for example after recordings are put
back from the Trash; the old index is kept beside it as
`index.jsonl.<epoch seconds>-<suffix>.bak`.

## On-device layout

Under the app data directory (`~/.local/share/fairspoken/training-data` on
macOS and Linux, `%LOCALAPPDATA%\Fairspoken\training-data` on Windows;
`FAIRSPOKEN_TRAINING_DATA_DIR` overrides it):

```text
training-data/
  index.jsonl          one entry per line (camelCase fields, as in meta.json)
  .index.lock          empty; the lock both apps share (see above)
  <id>/audio.wav
  <id>/meta.json
```

Treat this layout as internal; use the export for anything else.

## Export format (version 1)

**Export…** writes `fairspoken-training-data-<epoch seconds>.zip` to your
Downloads folder and shows it in the file manager:

```text
manifest.jsonl
polish.jsonl
README.txt
audio/<id>.wav
```

### manifest.jsonl

One dictation per line, in the NeMo manifest style, with paths relative to the
zip's root:

```json
{"audio_filepath": "audio/6f1c….wav", "duration": 4.2, "text": "Ask Claude Code to rebase the branch.",
 "id": "6f1c…", "created_at": 1791331200, "speech_model": "parakeet-tdt-0.6b-v3", "app_category": "code",
 "raw_text": "ask cloud code to rebase the branch", "polished_text": "Ask cloud code to rebase the branch.",
 "final_text": "Ask cloud code to rebase the branch.", "edited_text": "Ask Claude Code to rebase the branch."}
```

- `text` is `edited_text` when present, otherwise `final_text`. It is the best
  available reference, but it is not a verbatim transcript: polish removes
  fillers and false starts, and snippets expand. For ASR fine-tuning, prefer
  rows with `edited_text`, or compare `text` against `raw_text` and drop rows
  that differ by more than a few words.
- `polished_text` and `edited_text` are `null` when absent.
- For NeMo, rewrite `audio_filepath` to absolute paths after unzipping (for
  example with `jq`), then pass the file as `train_ds.manifest_filepath`.

### polish.jsonl

Prompt/completion pairs for polish LoRA training, in MLX-LM's `completions`
format:

```json
{"id": "6f1c…", "prompt": "ask cloud code to rebase the branch", "completion": "Ask Claude Code to rebase the branch."}
```

`prompt` is the speech model's text and `completion` is the same target as the
manifest's `text`. Wrap `prompt` in the polish system prompt you train with,
and hold back unchanged pairs (around 40%) so the model learns restraint.

### Compatibility

Fields may be added in later versions; readers should ignore unknown fields.
A change that removes or renames a field will bump the version in
`README.txt`.
