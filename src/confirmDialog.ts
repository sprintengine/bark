// A small sheet that asks before something can't be undone, as the Mac's
// confirmation dialogs do: a title, one line on what happens, and the
// destructive action beside Cancel. Drawn in the page, so it looks the same
// in every webview. Resolves true when the action is chosen.

export function confirmDialog(title: string, message: string, action: string, destructive = true): Promise<boolean> {
  return new Promise((resolve) => {
    const previous = document.activeElement as HTMLElement | null;
    const scrim = document.createElement("div");
    scrim.className = "dialog-scrim";
    const card = document.createElement("div");
    card.className = "dialog";
    card.setAttribute("role", "alertdialog");
    card.setAttribute("aria-modal", "true");
    const heading = Object.assign(document.createElement("h2"), { className: "dialog-title", textContent: title, id: "dialogTitle" });
    const body = Object.assign(document.createElement("p"), { className: "dialog-message", textContent: message, id: "dialogMessage" });
    card.setAttribute("aria-labelledby", heading.id);
    card.setAttribute("aria-describedby", body.id);
    const buttons = document.createElement("div");
    buttons.className = "dialog-buttons";
    const cancel = Object.assign(document.createElement("button"), { type: "button", className: "btn", textContent: "Cancel" });
    const ok = Object.assign(document.createElement("button"), { type: "button", className: destructive ? "btn btn-destructive" : "btn btn-primary", textContent: action });
    buttons.append(cancel, ok);
    card.append(heading, body, buttons);
    scrim.append(card);
    document.body.append(scrim);
    cancel.focus();

    const close = (answer: boolean) => {
      document.removeEventListener("keydown", onKey, true);
      scrim.remove();
      previous?.focus?.();
      resolve(answer);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(false); }
      else if (event.key === "Tab") {
        event.preventDefault();
        (document.activeElement === cancel ? ok : cancel).focus();
      }
    };
    document.addEventListener("keydown", onKey, true);
    cancel.addEventListener("click", () => close(false));
    ok.addEventListener("click", () => close(true));
    scrim.addEventListener("pointerdown", (event) => { if (event.target === scrim) close(false); });
  });
}

/** One line of bad news, with OK. */
export function notice(title: string, message: string): Promise<void> {
  return confirmDialog(title, message, "OK", false).then(() => undefined);
}
