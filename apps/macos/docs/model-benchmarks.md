# Speech model benchmarks (Models library figures)

The speed and accuracy bars in Fairspoken › Models come from one check, run the same way for
every model on an Apple M4 Mac (10 cores, 16 GB, macOS 26):

- **Audio:** 20 utterances from LibriSpeech test-clean (CC BY 4.0), 147 s in all, 16 kHz mono.
  No other recordings were used.
- **Engine:** the app's own code (`LocalSpeechRouter`: FluidAudio 0.17.5 for Parakeet, WhisperKit
  1.1.1 for Whisper, with the decoding options dictation uses), language `en`.
- **Speed:** each clip once to warm up, then 3 runs; the median per clip. RTFx is total audio
  divided by the sum of the medians (seconds of audio per second of compute).
- **Accuracy:** corpus word error rate over the 20 clips after a light English normaliser
  (lower case, punctuation dropped, common contractions expanded, hyphens split, numbers up to
  twenty as digits).
- **Memory:** the rise in system wired memory (where Core ML keeps Neural Engine weights) plus the
  app's own footprint while the model is loaded. Approximate: the Mac was in use.
- **Bars** (`ScoreScale`): accuracy 5 below 2.75 %, 4 below 3.5 %, 3 below 5 %, 2 below 8 %;
  speed 5 at 100× real time or more, 4 at 40×, 3 at 15×, 2 at 5×.

| Model | Variant | WER | RTFx | Memory | Download |
|---|---|---|---|---|---|
| Parakeet TDT 0.6B v3 † | FluidInference/parakeet-tdt-0.6b-v3-coreml | 2.07 % | 129× | 0.45 GB | 470 MB |
| Parakeet Ultra † | FluidInference/parakeet-ultra-coreml | 2.33 % | 120× | 0.6 GB | 613 MB |
| Whisper Tiny | openai_whisper-tiny | 7.77 % | 105× | 0.19 GB | 77 MB |
| Whisper Tiny (English) | openai_whisper-tiny.en | 5.70 % | 108× | 0.16 GB | 153 MB |
| Whisper Base | openai_whisper-base | 6.22 % | 57× | 0.22 GB | 147 MB |
| Whisper Base (English) | openai_whisper-base.en | 5.44 % | 65× | 0.24 GB | 147 MB |
| Whisper Small | openai_whisper-small_216MB | 4.40 % | 16× | 0.48 GB | 217 MB |
| Whisper Small (English) | openai_whisper-small.en_217MB | 2.33 % | 16× | 0.48 GB | 218 MB |
| Whisper Medium | openai_whisper-medium | 2.33 % | 5.1× | 2.0 GB | 1.53 GB |
| Whisper Medium (English) | openai_whisper-medium.en | 2.33 % | 5.7× | 1.8 GB | 1.53 GB |
| Whisper Large v2 | openai_whisper-large-v2_949MB | 2.33 % | 3.3× | 1.3 GB | 952 MB |
| Whisper Large v3 | openai_whisper-large-v3_947MB | 2.59 % | 3.5× | 1.3 GB | 948 MB |
| Whisper Large v3 Turbo | openai_whisper-large-v3-v20240930_626MB | 3.11 % | 8× | 1.0 GB | 627 MB |
| Distil-Whisper Large v3 | distil-whisper_distil-large-v3_594MB | 3.11 % | 9.2× | 0.95 GB | 595 MB |

Parakeet TDT 0.6B v2 has no figures yet (its bars are an estimate, and the library says so).

† Parakeet figures are from the earlier FluidAudio measurement on the same Mac, clips and method
on a quiet machine. Rerun alongside the Whisper models (other work running), v3 gave the same
2.07 % and 98–101×, so the Whisper speeds above are probably about a fifth lower than on a quiet
Mac. The ranking doesn't change.

**Reading the numbers.** One word is about 0.3 points on 20 clips, so differences under a point
are noise: the larger Whisper models are all within a word or two of Parakeet here, and published
full-test-set results rank Large v3 ahead of Medium and Small. Whisper decodes word by word, so
its speed falls with model size much more than Parakeet's; a 10 s dictation takes about 0.1 s on
Parakeet v3, 1.2 s on Large v3 Turbo and 3 s on Large v3. Whisper's first download also compiles
the model for the Neural Engine once (20 s for Tiny to 2.5 min for Medium on the M4).

To check a model through the app's own path:

```sh
build/Build/Products/Debug/Fairspoken.app/Contents/MacOS/Fairspoken --selftest <clip.wav> --model large-v3-turbo
```
