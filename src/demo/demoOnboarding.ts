// The setup window on the demo backend: /onboarding.html?demo#<step> (welcome,
// permissions, mic, model, try, improve, done), with
//
//   &platform=macos      the Mac's permissions (Accessibility; Windows otherwise)
//   &mic=denied          the microphone's permission (granted unless given)
//   &download=42         the chosen model downloading, at that percentage
//   &missing             the chosen model not downloaded
//   &said=<words>        Try it: a dictation that has just come back
import { emit } from "@tauri-apps/api/event";

type Respond = (cmd: string, args: Record<string, unknown> | undefined) => unknown;

export function onboardingDemo(params: URLSearchParams): { respond: (fallback: Respond) => Respond } | null {
  if (!location.pathname.endsWith("/onboarding.html")) return null;
  const platform = params.get("platform") === "macos" ? "macos" : "windows";
  const mic = params.get("mic") ?? "granted";

  const respond = (fallback: Respond): Respond => (cmd, args) => {
    switch (cmd) {
      case "get_permission_status":
        return platform === "macos"
          ? { platform, microphone: mic, accessibility: params.get("accessibility") ?? "not-determined", inputMonitoring: "not-determined" }
          : { platform, microphone: mic, accessibility: "not-needed", inputMonitoring: "not-needed" };
      case "get_dictation_models": {
        const models = fallback(cmd, args) as { model: string; cached: boolean }[];
        return params.has("missing") || params.has("download")
          ? models.map((entry) => entry.model === "parakeet-tdt-0.6b-v3" ? { ...entry, cached: false } : entry)
          : models;
      }
      default:
        return fallback(cmd, args);
    }
  };

  window.addEventListener("load", () => {
    setTimeout(() => {
      const percentage = Number(params.get("download"));
      if (params.has("download")) {
        void emit("model-prepare-progress", { model: "parakeet-tdt-0.6b-v3", percentage, message: "", done: false });
      }
      const said = params.get("said");
      if (said) void emit("transcript-history-updated", { item: { text: said, durationSeconds: 3.4 } });
    }, 400);
  });
  return { respond };
}
