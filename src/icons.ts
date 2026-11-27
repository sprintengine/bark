import { monogram, monogramHue } from "./historyStore";

// Line glyphs drawn in the style of the Mac's system symbols, for what the
// main window builds in script.
const PATHS: Record<string, string> = {
  copy: '<rect x="8.5" y="8.5" width="11" height="12" rx="2.2"/><path d="M15.5 8.5V6a2.2 2.2 0 0 0-2.2-2.2H6.7A2.2 2.2 0 0 0 4.5 6v7.3a2.2 2.2 0 0 0 2.2 2.2h1.8"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  pin: '<path d="M9 4h6l-1 6 3 3H7l3-3Z"/><path d="M12 13v7"/>',
  server: '<rect x="3.5" y="4.5" width="17" height="6.5" rx="1.5"/><rect x="3.5" y="13" width="17" height="6.5" rx="1.5"/><path d="M7 7.75h.01M7 16.25h.01"/>',
  trash: '<path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13"/><path d="M10.5 11v5.5M13.5 11v5.5"/>',
  pencil: '<path d="m4.5 19.5 1-4L15.8 5.2a1.8 1.8 0 0 1 2.5 0l.5.5a1.8 1.8 0 0 1 0 2.5L8.5 18.5Z"/><path d="m13.5 7.5 3 3"/>',
  book: '<path d="M6 3.5h11.5a1 1 0 0 1 1 1v15a1 1 0 0 1-1 1H6a1.5 1.5 0 0 1-1.5-1.5v-14A1.5 1.5 0 0 1 6 3.5Z"/><path d="M8.5 3.5v17"/>',
  pinOff: '<path d="M9 4h6l-1 6 3 3H7l3-3Z"/><path d="M12 13v7"/>',
  chevronDown: '<path d="m7 10 5 5 5-5"/>',
  chevronRight: '<path d="m9 6 6 6-6 6"/>',
  arrowUp: '<path d="M12 19V5M6 11l6-6 6 6"/>',
  returnKey: '<path d="M19 5v7a2 2 0 0 1-2 2H6"/><path d="m9.5 10.5-3.5 3.5 3.5 3.5"/>',
  laptop: '<rect x="4" y="5.5" width="16" height="10.5" rx="1.5"/><path d="M2 19h20"/>',
  mic: '<rect x="9" y="3" width="6" height="11.5" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor" stroke="none"/>',
  waveform: '<path d="M4 10.5v3M7.5 8v8M11 5v14M14.5 8.5v7M18 6.5v11M21 10.5v3"/>',
};

export function icon(name: keyof typeof PATHS | string, width = 1.7): string {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${PATHS[name] ?? ""}</svg>`;
}

/** An app as a small tile holding two letters, tinted by app; Bark's own notes show its mark. */
export function monogramEl(name: string, isNote: boolean, size: "sm" | "md" = "sm"): HTMLElement {
  const el = document.createElement("span");
  el.className = `monogram monogram--${size}`;
  el.setAttribute("aria-hidden", "true");
  if (isNote) {
    el.classList.add("monogram--mark");
    const img = document.createElement("img");
    img.src = "./src/assets/brand/dog-tile.jpg";
    img.alt = "";
    el.append(img);
  } else {
    el.textContent = monogram(name);
    el.dataset.hue = String(monogramHue(name));
  }
  return el;
}
