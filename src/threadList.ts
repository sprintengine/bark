import { invoke } from "@tauri-apps/api/core";
import * as history from "./historyStore";
import { icon, monogramEl } from "./icons";
import { errorMessage } from "./errors";

// The sidebar's thread list, as on the Mac: search, a filter, and the
// dictations grouped by day. A row shows the app and when, the first line,
// and its kind and length; under the pointer the time gives way to copy.
// ↑ and ↓ move through the list, esc goes back to Home and Delete deletes the
// open dictation (after asking).

interface Host { navigate(route: string): void; selected(): string | null }

const list = document.getElementById("threadList")!;
const search = document.getElementById("historySearch") as HTMLInputElement;
const clear = document.getElementById("historySearchClear") as HTMLButtonElement;
const filterButton = document.getElementById("historyFilter") as HTMLButtonElement;
const filterMenu = document.getElementById("historyFilterMenu")!;
const paletteKey = document.getElementById("paletteKey")!;
const FILTER_TITLES: Record<history.HistoryFilter, string> = { all: "All dictations", notes: "Notes", pinned: "Pinned" };

let host: Host;
let filter: history.HistoryFilter = "all";
let shown: history.Dictation[] = [];

export function focusSearch(): void { search.focus(); search.select(); }

export async function copyDictation(item: history.Dictation): Promise<void> {
  await invoke("copy_note", { id: item.id });
}

export async function deleteDictation(item: history.Dictation): Promise<boolean> {
  if (!window.confirm(`Delete this dictation?\n\n“${history.title(item)}” is removed from history. This can't be undone.`)) return false;
  try {
    await invoke("delete_note", { id: item.id });
    if (item.details) await invoke("delete_transcript_history_item", { id: item.details.id }).catch(() => {});
  } catch (error) {
    window.alert(`Couldn't delete it: ${errorMessage(error)}`);
    return false;
  }
  await history.refresh();
  return true;
}

function row(item: history.Dictation, selected: boolean, recede: boolean): HTMLElement {
  const el = document.createElement("div");
  el.className = "thread";
  el.id = `thread-${item.id}`;
  el.setAttribute("role", "option");
  el.setAttribute("aria-selected", String(selected));
  if (recede) el.classList.add("thread--recede");
  const name = history.appName(item);

  const top = document.createElement("div");
  top.className = "thread-top";
  const app = document.createElement("span");
  app.className = "thread-app";
  app.textContent = name;
  const when = document.createElement("time");
  when.className = "thread-age";
  when.dateTime = new Date(item.createdAt).toISOString();
  when.title = new Date(item.createdAt).toLocaleString();
  when.textContent = history.age(item.createdAt);
  const copy = document.createElement("button");
  copy.type = "button";
  copy.className = "row-action";
  copy.setAttribute("aria-label", "Copy");
  copy.title = "Copy";
  copy.innerHTML = icon("copy");
  copy.addEventListener("click", (event) => {
    event.stopPropagation();
    void copyDictation(item).then(() => {
      copy.innerHTML = icon("check");
      el.classList.add("thread--copied");
      setTimeout(() => { copy.innerHTML = icon("copy"); el.classList.remove("thread--copied"); }, 1400);
    }).catch(() => {});
  });
  const pin = item.pinned ? Object.assign(document.createElement("span"), { className: "thread-pin", title: "Pinned", innerHTML: icon("pin") }) : null;
  top.append(monogramEl(name, item.isNote), app, ...(pin ? [pin] : []), when, copy);

  const title = document.createElement("div");
  title.className = "thread-title";
  title.textContent = history.title(item);

  const meta = document.createElement("div");
  meta.className = "thread-meta";
  const glyph = document.createElement("span");
  glyph.className = "type-glyph";
  glyph.setAttribute("aria-hidden", "true");
  const text = document.createElement("span");
  text.textContent = history.meta(item);
  meta.append(glyph, text);
  if (item.details?.location === "remote-host") {
    const server = document.createElement("span");
    server.className = "thread-server";
    server.title = "Ran on Bark Server";
    server.innerHTML = icon("server");
    meta.append(server);
  }

  el.append(top, title, meta);
  el.setAttribute("aria-label", `${name}, ${when.title}, ${history.title(item)}, ${history.meta(item)}`);
  el.addEventListener("click", () => {
    host.navigate(`dictation/${item.id}`);
    list.focus({ preventScroll: true });
  });
  el.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    openContextMenu(item, event.clientX, event.clientY);
  });
  return el;
}

function empty(): HTMLElement {
  const searching = search.value.trim() !== "" || filter !== "all";
  const el = document.createElement("div");
  el.className = "thread-empty";
  const t = document.createElement("div");
  t.className = "thread-empty-title";
  t.textContent = searching ? "Nothing matches" : "No dictations yet";
  const d = document.createElement("div");
  d.className = "thread-empty-detail";
  d.textContent = searching ? "Try other words, or show all dictations." : "Each one appears here, newest first, with the app it went to.";
  el.append(t, d);
  return el;
}

export function renderThreadList(): void {
  shown = history.visible(search.value, filter);
  const selected = host.selected();
  const nodes: HTMLElement[] = [];
  if (shown.length === 0 && history.isLoaded()) nodes.push(empty());
  for (const group of history.groups(shown)) {
    const head = document.createElement("div");
    head.className = "thread-group";
    head.setAttribute("role", "presentation");
    const label = document.createElement("span");
    label.textContent = group.title;
    const count = document.createElement("span");
    count.className = "num";
    count.textContent = String(group.items.length);
    head.append(label, count);
    nodes.push(head);
    for (const item of group.items) nodes.push(row(item, item.id === selected, group.title !== "Today"));
  }
  list.replaceChildren(...nodes);
  const current = selected ? document.getElementById(`thread-${selected}`) : null;
  if (current) list.setAttribute("aria-activedescendant", current.id); else list.removeAttribute("aria-activedescendant");
  current?.scrollIntoView({ block: "nearest" });
}

// ── Context menu: copy, pin, delete ──

let contextMenu: HTMLElement | null = null;
function closeContextMenu(): void { contextMenu?.remove(); contextMenu = null; }
function openContextMenu(item: history.Dictation, x: number, y: number): void {
  closeContextMenu();
  const menu = document.createElement("div");
  menu.className = "menu menu--floating";
  menu.setAttribute("role", "menu");
  const add = (label: string, action: () => void, danger = false) => {
    const b = document.createElement("button");
    b.type = "button";
    b.setAttribute("role", "menuitem");
    b.textContent = label;
    if (danger) b.className = "menu-danger";
    b.addEventListener("click", () => { closeContextMenu(); action(); });
    menu.append(b);
  };
  add("Copy", () => void copyDictation(item));
  add(item.pinned ? "Unpin" : "Pin", () => void invoke("set_note_pinned", { id: item.id, pinned: !item.pinned }).then(() => history.refresh()).catch(() => {}));
  menu.append(Object.assign(document.createElement("div"), { className: "menu-sep" }));
  add("Delete…", () => void deleteDictation(item).then((gone) => { if (gone && host.selected() === item.id) host.navigate("home"); }), true);
  document.body.append(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = `${Math.min(x, window.innerWidth - r.width - 8)}px`;
  menu.style.top = `${Math.min(y, window.innerHeight - r.height - 8)}px`;
  contextMenu = menu;
  (menu.querySelector("button") as HTMLButtonElement | null)?.focus();
}
document.addEventListener("pointerdown", (event) => { if (contextMenu && !contextMenu.contains(event.target as Node)) closeContextMenu(); });
document.addEventListener("keydown", (event) => { if (event.key === "Escape" && contextMenu) { event.preventDefault(); closeContextMenu(); } }, true);

// ── Filter ──

function setFilter(next: history.HistoryFilter): void {
  filter = next;
  for (const b of filterMenu.querySelectorAll<HTMLElement>("[data-filter]")) b.setAttribute("aria-checked", String(b.dataset.filter === next));
  filterButton.classList.toggle("is-active", next !== "all");
  filterButton.title = `Show: ${FILTER_TITLES[next]}`;
  filterButton.setAttribute("aria-label", `Filter, ${FILTER_TITLES[next]}`);
  renderThreadList();
}

function toggleFilterMenu(open = filterMenu.hidden): void {
  filterMenu.hidden = !open;
  filterButton.setAttribute("aria-expanded", String(open));
  if (open) (filterMenu.querySelector('[aria-checked="true"]') as HTMLElement | null)?.focus();
}

async function deleteAll(): Promise<void> {
  const all = history.dictations();
  if (all.length === 0) return;
  if (!window.confirm(`Delete all ${all.length} dictations and notes?\n\nTheir text is removed from this computer. Your usage stats and any kept recordings stay. This can't be undone.`)) return;
  for (const item of all) {
    await invoke("delete_note", { id: item.id }).catch(() => {});
    if (item.details) await invoke("delete_transcript_history_item", { id: item.details.id }).catch(() => {});
  }
  host.navigate("home");
  await history.refresh();
}

export function initThreadList(h: Host): void {
  host = h;
  history.subscribe(renderThreadList);
  document.addEventListener("home-screen-changed", renderThreadList);

  const syncSearch = () => {
    const has = search.value !== "";
    clear.hidden = !has;
    paletteKey.hidden = has || document.activeElement === search;
    renderThreadList();
  };
  search.addEventListener("input", syncSearch);
  search.addEventListener("focus", syncSearch);
  search.addEventListener("blur", syncSearch);
  search.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      if (search.value) { search.value = ""; syncSearch(); } else search.blur();
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      if (shown[0]) { host.navigate(`dictation/${shown[0].id}`); list.focus(); }
    }
  });
  clear.addEventListener("click", () => { search.value = ""; syncSearch(); search.focus(); });

  filterButton.addEventListener("click", () => toggleFilterMenu());
  filterMenu.addEventListener("click", (event) => {
    const b = (event.target as HTMLElement).closest<HTMLElement>("button");
    if (!b) return;
    toggleFilterMenu(false);
    if (b.dataset.filter) setFilter(b.dataset.filter as history.HistoryFilter);
    else if (b.dataset.filterAction === "delete-all") void deleteAll();
  });
  document.addEventListener("pointerdown", (event) => {
    if (!filterMenu.hidden && !filterMenu.contains(event.target as Node) && !filterButton.contains(event.target as Node)) toggleFilterMenu(false);
  });
  filterMenu.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); toggleFilterMenu(false); filterButton.focus(); }
  });
  for (const b of document.querySelectorAll<HTMLElement>('[data-action="delete-all"]')) b.addEventListener("click", () => void deleteAll());

  list.addEventListener("keydown", (event) => {
    const index = shown.findIndex((item) => item.id === host.selected());
    if (event.key === "ArrowDown") {
      event.preventDefault();
      const next = shown[Math.min(index + 1, shown.length - 1)];
      if (next) host.navigate(`dictation/${next.id}`);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      if (index <= 0) host.navigate("home"); else host.navigate(`dictation/${shown[index - 1].id}`);
    } else if (event.key === "Delete" || event.key === "Backspace") {
      if (index < 0) return;
      event.preventDefault();
      const item = shown[index];
      void deleteDictation(item).then((gone) => {
        if (!gone) return;
        const next = shown[index] ?? shown[index - 1];
        host.navigate(next ? `dictation/${next.id}` : "home");
      });
    } else if (event.key === "Enter" && index >= 0) {
      event.preventDefault();
      document.dispatchEvent(new CustomEvent("dictation-edit"));
    }
  });
  syncSearch();
}
