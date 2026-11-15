import { speechInfo } from "./modelCatalog";

// People-facing names for the speech model ids in Settings: the same names
// as Models and setup.
export function speechModelName(model: string): string {
  return speechInfo(model).name;
}

// The short name the sidebar status card has room for: "Parakeet v3".
export function speechModelShortName(model: string): string {
  if (model === "parakeet-ultra") return "Parakeet Ultra";
  return model.startsWith("parakeet") ? `Parakeet ${model.endsWith("-v2") ? "v2" : "v3"}` : `Whisper ${model}`;
}
