// Where the backend put a finished dictation (DictationDelivery in lib.rs).
export type DictationDelivery = "inserted" | "copied" | "insertFailed" | "notCopied";

export interface DictationOutcome {
  transcript: string;
  delivery: DictationDelivery;
}

// What the pill says when a dictation did not reach the cursor; null when the
// plain Copied flash is right. The text is never lost: it is on the clipboard,
// or (when the clipboard failed) in History and Notes.
export function deliveryNotice(delivery: DictationDelivery | null | undefined, pasteKeys: string): string | null {
  if (delivery === "insertFailed") return `Copied — press ${pasteKeys} to paste`;
  if (delivery === "notCopied") return "Not copied — saved in History";
  return null;
}
