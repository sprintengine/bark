// Settings in the main area, as on the Mac: one page at a time, chosen in the
// settings sidebar, under the page's title and one quiet line. Typing in the
// sidebar's search shows every row that matches, from every page.

export const categories = ["general", "history", "activity", "transcription", "styles", "dictionary", "server", "updates", "about"] as const;
export type Category = (typeof categories)[number];

export const PAGES: Record<Category, { title: string; subtitle: string }> = {
  general: { title: "General", subtitle: "Your shortcut and microphone, and what happens when you stop speaking." },
  history: { title: "History", subtitle: "Every dictation and note stays on this computer, newest first." },
  activity: { title: "Activity", subtitle: "Warnings and errors worth a look." },
  transcription: { title: "Transcription", subtitle: "Where Bark listens, the model that hears you, and what cleanup does." },
  styles: { title: "App styles", subtitle: "Bark shapes what you say for the app you are in. Anything not listed uses the defaults." },
  dictionary: { title: "Dictionary", subtitle: "Names and terms spelt your way, and words Bark keeps mishearing." },
  server: { title: "Bark Server", subtitle: "Transcribe on another computer running Bark Server, over your own network." },
  updates: { title: "Updates", subtitle: "Bark checks for new versions and asks before installing one." },
  about: { title: "About", subtitle: "" },
};

/** Older names for pages, from deep links and the palette. */
const ALIASES: Record<string, Category> = {
  "app-styles": "styles", polish: "transcription", keybindings: "general", audio: "general",
  appearance: "general", host: "server", vocabulary: "dictionary",
};

let category: Category = "general";
let query = "";
const positions = new Map<Category, number>();
const screen = document.querySelector<HTMLElement>("#screen-settings")!;
const content = screen.querySelector<HTMLElement>(".settings-content")!;
const buttons = [...document.querySelectorAll<HTMLButtonElement>("[data-settings-category]")];
const pages = [...screen.querySelectorAll<HTMLElement>("[data-settings-page]")];
const titleEl = document.getElementById("settingsTitle")!;
const subtitleEl = document.getElementById("settingsSubtitle")!;
const noResults = document.getElementById("settingsNoResults")!;
const searchInput = document.getElementById("settingsSearch") as HTMLInputElement;

export function currentCategory(): Category { return category; }
export function settingsQuery(): string { return query; }

export function resolveCategory(value: string): Category | null {
  if ((categories as readonly string[]).includes(value)) return value as Category;
  return ALIASES[value] ?? null;
}

function announce(): void {
  document.dispatchEvent(new CustomEvent("settings-category-changed", { detail: { category, query } }));
}

function showPage(): void {
  const { title, subtitle } = PAGES[category];
  titleEl.parentElement!.hidden = category === "about";
  titleEl.textContent = title;
  subtitleEl.textContent = subtitle;
  subtitleEl.hidden = !subtitle;
  noResults.hidden = true;
  for (const page of pages) {
    page.hidden = page.dataset.settingsPage !== category;
    page.removeAttribute("data-results");
  }
  for (const el of screen.querySelectorAll<HTMLElement>("[data-search-hidden]")) {
    el.hidden = false;
    el.removeAttribute("data-search-hidden");
  }
  for (const button of buttons) {
    if (button.dataset.settingsCategory === category) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  }
}

export function selectSettingsCategory(value: string): void {
  const next = resolveCategory(value);
  if (!next) return;
  if (!query) positions.set(category, content.scrollTop);
  category = next;
  if (query) { query = ""; searchInput.value = ""; }
  showPage();
  content.scrollTop = positions.get(category) ?? 0;
  announce();
}

// ── Search: every row whose words hold every word of the query ──

function hideForSearch(el: HTMLElement): void {
  if (el.hidden) return;
  el.hidden = true;
  el.setAttribute("data-search-hidden", "");
}

function search(text: string): void {
  query = text.trim();
  if (!query) {
    showPage();
    announce();
    return;
  }
  showPage();
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  let total = 0;
  for (const page of pages) {
    const pageName = PAGES[page.dataset.settingsPage as Category]?.title ?? "";
    page.hidden = false;
    page.setAttribute("data-results", pageName);
    let pageCount = 0;
    for (const section of page.querySelectorAll<HTMLElement>(":scope > .settings-section, :scope > div > .settings-section")) {
      const heading = section.querySelector("h2")?.textContent ?? "";
      if (section instanceof HTMLDetailsElement) section.open = true;
      let sectionCount = 0;
      for (const row of section.querySelectorAll<HTMLElement>(".row")) {
        if (row.closest("[hidden]") && !row.closest("[data-search-hidden]")) continue;
        const hay = `${pageName} ${heading} ${row.textContent ?? ""}`.toLowerCase();
        if (words.every((word) => hay.includes(word))) sectionCount++;
        else hideForSearch(row);
      }
      if (sectionCount === 0) hideForSearch(section);
      pageCount += sectionCount;
    }
    if (pageCount === 0) hideForSearch(page);
    total += pageCount;
  }
  for (const button of buttons) button.removeAttribute("aria-current");
  titleEl.parentElement!.hidden = false;
  titleEl.textContent = "Results";
  subtitleEl.hidden = false;
  subtitleEl.textContent = total === 0
    ? `Nothing matches “${query}”. Try another word, or press esc to clear the search.`
    : `Every setting that mentions “${query}”.`;
  content.scrollTop = 0;
  announce();
}

for (const button of buttons) {
  button.addEventListener("click", () => selectSettingsCategory(button.dataset.settingsCategory!));
}
searchInput.addEventListener("input", () => search(searchInput.value));
searchInput.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && searchInput.value) {
    event.preventDefault();
    event.stopPropagation();
    searchInput.value = "";
    search("");
  }
});

// App styles need AI polish: say so where the styles would be.
const tones = document.getElementById("polishTonesPanel");
const needPolish = document.getElementById("stylesNeedPolish");
if (tones && needPolish) {
  const sync = () => { needPolish.hidden = !tones.hidden; };
  new MutationObserver(sync).observe(tones, { attributes: true, attributeFilter: ["hidden"] });
  sync();
}

showPage();
