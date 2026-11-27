import { invoke } from "@tauri-apps/api/core";
import * as history from "./historyStore";
import { diffPreview, type PreviewRun } from "./previewDiff";
import { icon } from "./icons";
import { copyDictation, deleteDictation } from "./threadList";
import { isMacOS } from "./shortcuts";
import { speechModelShortName } from "./speechModels";
import { errorMessage } from "./errors";

// A dictation opened from the thread list, as on the Mac: what you said in a
// grey bubble, where the time went after you let go, what was pasted, what
// polish changed word by word, and a box to correct the text. The actions sit
// in a card beside it (or under it, in a narrow window), and the top bar's
// button hides them.

const PANEL_KEY = "bark.dictationPanelHidden";
const panelToggle = document.getElementById("panelToggle") as HTMLButtonElement;
let panelHidden = (() => { try { return localStorage.getItem(PANEL_KEY) === "1"; } catch { return false; } })();
let current: { root: HTMLElement; id: string } | null = null;
let foldedChanges = false;

function syncPanelToggle(): void {
  const label = panelHidden ? "Show actions" : "Hide actions";
  panelToggle.setAttribute("aria-label", label);
  panelToggle.title = label;
  panelToggle.setAttribute("aria-pressed", String(!panelHidden));
  panelToggle.classList.toggle("is-on", !panelHidden);
}
panelToggle.addEventListener("click", () => {
  panelHidden = !panelHidden;
  try { localStorage.setItem(PANEL_KEY, panelHidden ? "1" : "0"); } catch { /* session only */ }
  syncPanelToggle();
  if (current) renderDictation(current.root, current.id);
});
syncPanelToggle();

function el<K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function formatMs(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)} ms`;
  return `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)} s`;
}

function clock(at: number): string {
  return new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// ── What you said ──

function bubble(item: history.Dictation, runs: PreviewRun[] | null): HTMLElement {
  const said = el("div", "said-bubble");
  if (runs) {
    // What polish took out stays in the bubble, dimmed.
    for (const run of runs) {
      if (run.kind === "insert") continue;
      const span = el("span", run.kind === "delete" ? "said-dim" : undefined, run.text);
      said.append(span);
    }
  } else {
    said.textContent = item.details?.rawText ?? item.text;
  }
  return said;
}

function metaLine(item: history.Dictation): HTMLElement {
  const meta = el("div", "said-meta");
  const parts = [clock(item.createdAt)];
  if (item.durationSeconds > 0) parts.push(`${item.durationSeconds.toFixed(1)} s`);
  meta.textContent = parts.join("  ");
  if (!item.isNote) {
    const where = el("span", "said-where", `→ ${history.appName(item)}`);
    meta.append(document.createTextNode("  "), where);
  }
  return meta;
}

// ── Where the time went ──

type Step = { kind: "model" | "polish" | "other"; title: string; ms: number };

function timeline(item: history.Dictation): HTMLElement | null {
  const t = item.details?.timings;
  if (!t || t.totalMs <= 0) return null;
  const remote = item.details?.location === "remote-host";
  const steps: Step[] = [
    { kind: "model", title: remote ? "Bark Server" : "Speech model", ms: Math.min(t.transcribeMs, t.totalMs) },
    { kind: "polish", title: "Polish", ms: t.polishMs },
  ];
  const rest = t.totalMs - steps.reduce((sum, s) => sum + s.ms, 0);
  steps.push({ kind: "other", title: "Other steps", ms: Math.max(0, rest) });
  const shown = steps.filter((s) => s.ms > 0);
  const wrap = el("div", "timeline");
  const headline = (() => {
    const total = `Pasted ${formatMs(t.totalMs)} after you let go`;
    const top = [...shown].sort((a, b) => b.ms - a.ms)[0];
    if (t.totalMs < 1500 || !top || top.ms < t.totalMs * 0.6) return total;
    return `${total}, mostly ${top.kind === "model" ? (remote ? "Bark Server" : "the speech model") : top.kind === "polish" ? "polish" : "steps not timed"}`;
  })();
  const line = el("div", "timeline-line", headline);
  const bar = el("div", "timeline-bar");
  bar.setAttribute("aria-hidden", "true");
  for (const step of shown) {
    const seg = el("span", `timeline-seg timeline-seg--${step.kind}`);
    seg.style.flexGrow = String(Math.max(step.ms, t.totalMs * 0.02));
    seg.addEventListener("pointerenter", () => {
      wrap.classList.add("is-focused");
      seg.classList.add("is-lit");
      line.replaceChildren(el("span", `timeline-dot timeline-seg--${step.kind}`), el("span", "timeline-step", step.title), el("span", "timeline-ms", formatMs(step.ms)));
    });
    seg.addEventListener("pointerleave", () => {
      wrap.classList.remove("is-focused");
      seg.classList.remove("is-lit");
      line.textContent = headline;
    });
    bar.append(seg);
  }
  wrap.setAttribute("aria-label", `${headline}. ${shown.map((s) => `${s.title} ${formatMs(s.ms)}`).join(", ")}`);
  wrap.append(line, bar);
  return wrap;
}

// ── What polish changed ──

function changes(item: history.Dictation, runs: PreviewRun[]): HTMLElement {
  const wrap = el("div", "changes");
  const toggle = el("button", "changes-toggle");
  toggle.type = "button";
  const polishMs = item.details?.timings?.polishMs ?? 0;
  toggle.innerHTML = `<span>${polishMs > 0 ? `Polished in ${formatMs(polishMs)}` : "Polished"}</span>${icon("chevronDown", 2.2)}`;
  toggle.setAttribute("aria-expanded", String(!foldedChanges));
  toggle.addEventListener("click", () => {
    foldedChanges = !foldedChanges;
    if (current) renderDictation(current.root, current.id);
  });
  wrap.append(toggle);
  if (foldedChanges) return wrap;

  const removed = runs.filter((r) => r.kind === "delete").map((r) => r.text.trim()).filter(Boolean);
  const added = runs.filter((r) => r.kind === "insert").map((r) => r.text.trim()).filter(Boolean);
  const layoutChanged = runs.some((r) => r.kind !== "equal" && r.text.trim() === "" && r.text.includes("\n"));
  const table = el("div", "changes-table");
  const addRow = (step: string, result: string, muted?: string) => {
    const r = el("div", "changes-row");
    const v = el("span", "changes-result", result);
    if (muted) v.append(el("span", "changes-muted", ` ${muted}`));
    r.append(el("span", "changes-step", step), v);
    table.append(r);
  };
  addRow("AI polish", `${removed.length + added.length} change${removed.length + added.length === 1 ? "" : "s"} to wording, capitals or punctuation`);
  if (layoutChanged) addRow("Formatting", "Laid out in paragraphs");
  if (item.details?.model) addRow("Speech model", speechModelShortName(item.details.model));
  else if (item.details?.location === "remote-host") addRow("Speech model", "Bark Server");
  wrap.append(table);

  // Word by word, against what you said.
  const words = (rs: PreviewRun[], kind: PreviewRun["kind"]) => rs.filter((r) => r.kind === kind).reduce((n, r) => n + history.wordCount(r.text), 0);
  const plus = words(runs, "insert"), minus = words(runs, "delete");
  const edits = runs.filter((r) => r.kind !== "equal" && r.text.trim() !== "").length;
  const card = el("div", "diff-card");
  const head = el("div", "diff-head");
  head.append(el("span", "diff-title", `${edits} edit${edits === 1 ? "" : "s"} vs what you said`), el("span", "diff-plus", `+${plus}`), el("span", "diff-minus", `−${minus}`));
  const copy = el("button", "icon-btn icon-btn--sm diff-copy");
  copy.type = "button";
  copy.title = "Copy what you said";
  copy.setAttribute("aria-label", "Copy what you said");
  copy.innerHTML = icon("copy");
  copy.addEventListener("click", () => void navigator.clipboard.writeText(item.details?.rawText ?? "").catch(() => {}));
  head.append(el("span", "grow-spacer"), copy);
  const body = el("div", "diff-body");
  for (const run of runs) {
    // A change of spacing or line breaks alone is layout, not an edit.
    const layout = run.kind !== "equal" && run.text.trim() === "";
    if (layout && run.kind === "delete") { body.append(el("span", "diff-eq", " ")); continue; }
    body.append(el("span", run.kind === "equal" || layout ? "diff-eq" : run.kind === "insert" ? "diff-ins" : "diff-del", run.text));
  }
  card.append(head, body);
  wrap.append(card);
  return wrap;
}

// ── Actions ──

function keycap(text: string): HTMLElement { return el("kbd", "keycap", text); }

function actionRow(label: string, glyph: string, action: () => void, opts: { key?: string; danger?: boolean; detail?: string } = {}): HTMLButtonElement {
  const b = el("button", `action-row${opts.danger ? " action-row--danger" : ""}`);
  b.type = "button";
  b.innerHTML = icon(glyph);
  b.append(el("span", "action-label", label));
  if (opts.detail) b.append(el("span", "action-detail", opts.detail));
  b.append(el("span", "grow-spacer"));
  if (opts.key) b.append(keycap(opts.key));
  b.addEventListener("click", action);
  return b;
}

function actions(item: history.Dictation, startEdit: () => void): HTMLElement {
  const card = el("div", "actions-card");
  const mac = isMacOS();
  const copy = actionRow("Copy text", "copy", () => {
    void copyDictation(item).then(() => {
      const label = copy.querySelector(".action-label");
      if (label) { label.textContent = "Copied"; setTimeout(() => { label.textContent = "Copy text"; }, 1400); }
    });
  }, { key: mac ? "⇧⌘C" : "Ctrl+Shift+C" });
  card.append(
    copy,
    actionRow("Edit text", "pencil", startEdit, { key: "↵" }),
    actionRow(item.pinned ? "Unpin" : "Pin", "pin", () => void invoke("set_note_pinned", { id: item.id, pinned: !item.pinned }).then(() => history.refresh()).catch(() => {})),
    el("div", "actions-sep"),
    actionRow("Delete", "trash", () => void deleteDictation(item), { danger: true, key: mac ? "⌫" : "Del" }),
  );
  return card;
}

// ── Correct the text ──

function corrector(item: history.Dictation): { box: HTMLElement; focus: () => void } {
  const box = el("div", "composer composer--correct");
  const field = el("div", "composer-field");
  const area = el("textarea");
  area.rows = 1;
  area.placeholder = "Correct the text: click here, change it, press ↵ to save";
  area.setAttribute("aria-label", "Correct the text");
  const bar = el("div", "composer-bar");
  const kind = el("span", "composer-kind");
  kind.append(el("span", "type-glyph"), document.createTextNode(item.isNote ? "Note" : item.details?.polished ? "Polished" : "Dictation"));
  const engine = el("span", "engine-chip engine-chip--static");
  if (!item.isNote) {
    engine.innerHTML = icon(item.details?.location === "remote-host" ? "server" : "laptop", 1.6);
    engine.append(el("span", "engine-where", item.details?.location === "remote-host" ? "Bark Server"
      : item.details?.model ? speechModelShortName(item.details.model) : "This PC"));
  }
  const save = el("button", "round-btn");
  save.type = "button";
  save.innerHTML = icon("arrowUp", 2.2);
  save.setAttribute("aria-label", "Save the correction");
  save.title = "Save (↵)";
  save.disabled = true;
  const status = el("span", "composer-status");
  bar.append(kind, status, el("span", "composer-spacer"), engine, save);
  field.append(area);
  box.append(field, bar);

  const grow = () => { area.style.height = "auto"; area.style.height = `${Math.min(area.scrollHeight, 220)}px`; };
  const dirty = () => area.value.trim() !== "" && area.value.trim() !== item.text.trim();
  const sync = () => { save.disabled = !dirty(); box.classList.toggle("is-dirty", dirty()); grow(); };
  area.addEventListener("focus", () => { if (!area.value) { area.value = item.text; sync(); } });
  area.addEventListener("blur", () => { if (!dirty()) { area.value = ""; sync(); } });
  area.addEventListener("input", sync);
  const commit = async () => {
    if (!dirty()) return;
    try {
      await invoke("update_note", { id: item.id, text: area.value.trim() });
      area.value = "";
      area.blur();
      await history.refresh();
    } catch (error) {
      status.textContent = errorMessage(error);
    }
  };
  area.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void commit(); }
    else if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); area.value = ""; area.blur(); sync(); }
  });
  save.addEventListener("click", () => void commit());
  return { box, focus: () => area.focus() };
}

// ── The view ──

export function renderDictation(root: HTMLElement, id: string): void {
  const item = history.dictation(id);
  if (!item) { root.replaceChildren(); return; }
  if (current?.id !== id) foldedChanges = false;
  current = { root, id };
  const raw = item.details?.rawText?.trim();
  const runs = raw && raw !== item.text.trim() ? diffPreview(raw, item.text) : null;

  const convo = el("div", "conversation");
  if (!item.isNote) {
    const said = el("div", "said");
    said.append(bubble(item, runs), metaLine(item));
    convo.append(said);
    const line = timeline(item);
    if (line) convo.append(line);
  } else {
    convo.append(metaLine(item));
  }
  const pasted = el("div", "pasted");
  for (const para of item.text.split(/\n{2,}/)) {
    pasted.append(el("p", undefined, para));
  }
  convo.append(pasted);
  if (runs) convo.append(changes(item, runs));

  const { box, focus } = corrector(item);
  const main = el("div", "dictation-main");
  main.append(convo);
  const layout = el("div", "dictation-layout");
  layout.append(main);
  if (!panelHidden) layout.append(actions(item, focus));
  const foot = el("div", "dictation-foot");
  const footInner = el("div", "dictation-foot-inner");
  footInner.append(box);
  foot.append(footInner);
  const scroller = el("div", "dictation-scroll");
  scroller.append(layout);
  root.replaceChildren(scroller, foot);
  root.classList.toggle("has-panel", !panelHidden);
}

document.addEventListener("dictation-edit", () => {
  (current?.root.querySelector(".composer--correct textarea") as HTMLTextAreaElement | null)?.focus();
});
document.addEventListener("keydown", (event) => {
  if (!current || !current.root.classList.contains("active")) return;
  const mod = isMacOS() ? event.metaKey : event.ctrlKey;
  if (mod && event.shiftKey && event.key.toLowerCase() === "c") {
    const item = history.dictation(current.id);
    if (item) { event.preventDefault(); void copyDictation(item); }
  }
});
