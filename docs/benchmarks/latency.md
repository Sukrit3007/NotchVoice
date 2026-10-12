# Latency and accuracy baseline

Dictation pipeline, measured with `Tools/Bench/run.sh` (see `README.md` in this
folder). Raw output: `baseline-2026-10-12-m1pro-release.json`.

| | |
|---|---|
| Date | 2026-10-12 |
| Machine | MacBook Pro (MacBookPro18,3), Apple M1 Pro, 16 GB, on power |
| macOS | 27.0 (26A5425a, beta) |
| Toolchain | Xcode 27.0 (27A5228h), Swift 6.4 |
| Build | Release, commit `45a04d7` |
| Speech model | `openai_whisper-large-v3-v20240930_turbo_632MB` (the app's default, "Accurate"), WhisperKit 0.18.0, language `en` |
| Cleanup | **None ran.** Apple Intelligence reports `modelNotReady` on this Mac, and the local Qwen model is not installed (deliberately not downloaded) |
| Runs | 1 cold pass + 5 warm passes (median), 10 clips, 77 s of audio |

## Launch

| Step | Time | How measured |
|---|--:|---|
| Hugging Face check in `prepare` (2 repo listings + 22 sequential HEAD requests) | ~6.1 s | **Estimate.** The same requests replayed with `curl` from this Mac: 0.7 s + 5.4 s. Not timed inside the app |
| CoreML load + prewarm (`WhisperKitService.load(from:)`) | 5.2 s | Bench, CoreML cache warm |
| First dictation after the load (2.1 s clip) | 0.99 s | Bench. Warm median for the same clip is 0.84 s |

Together that is about 11 s after every launch during which a dictation is
dropped, close to the ~11.7 s logged earlier in the milestone-1 notes. A
first-ever launch, which compiles the model for the Neural Engine, was not
measured: it would mean wiping the app's CoreML cache.

## Per dictation

Times in ms, from key-up to text ready to paste. Recording, the key-down
Accessibility read, the dictionary read and the paste are not included. Paste
adds an 80 ms settle plus up to 250 ms waiting for the target (code constants,
not measured here).

| Clip | Audio s | Transcribe cold | Transcribe warm | ×RT | Cleanup | Fit | Total warm | WER raw | WER final |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| chat-short | 2.1 | 988 | 843 | 2.5 | — | 0.02 | 843 | 0.0% | 0.0% |
| chat-question | 2.2 | 757 | 840 | 2.6 | — | 0.01 | 840 | 0.0% | 0.0% |
| self-correction | 4.1 | 824 | 893 | 4.6 | — | 0.02 | 893 | 0.0% | 22.2% |
| code-term † | 3.8 | 743 | 789 | 4.9 | — | 0.00 | 789 | 100.0% | 100.0% |
| email | 4.8 | 897 | 963 | 4.9 | — | 0.02 | 963 | 33.3% | 33.3% |
| names † | 5.7 | 958 | 974 | 5.8 | — | 0.00 | 974 | 100.0% | 100.0% |
| list | 6.7 | 1108 | 1077 | 6.3 | — | 0.03 | 1077 | 0.0% | 0.0% |
| numbers | 9.1 | 1187 | 1128 | 8.0 | — | 0.02 | 1128 | 8.7% | 8.7% |
| update-medium | 11.5 | 1471 | 1325 | 8.7 | — | 0.03 | 1325 | 0.0% | 0.0% |
| paragraph-long | 27.1 | 2512 | 2286 | 11.9 | — | 0.06 | 2286 | 0.0% | 0.0% |
| **All** | 77.1 | 11444 | 11118 | | | | 11118 | **14.0%** | **15.0%** |

† These clips have custom words, which go to the decoder as a bias prompt. With
any bias prompt the transcript currently comes back **empty** (see below), so
their times are for an empty decode and their WER is 100%.

### Custom words (bias prompt): broken at this commit

| Clip | Terms | WER raw with | WER raw without | Transcribe warm with | without |
|---|---|--:|--:|--:|--:|
| code-term | fetchUserProfile | 100.0% (empty) | 25.0% | 789 | 986 |
| names | Priya, Propsoch, Arjun, NotchVoice, TestFlight | 100.0% (empty) | 25.0% | 974 | 1183 |

WhisperKit 0.18 with `usePrefillPrompt: true` and any `promptTokens` ends the
decode at once with `<|endoftext|>`, so `WhisperKitService.transcribe` throws
`.empty`. In the app this hits every dictation by someone with a custom word,
and every dictation into a field whose text is read for context ("Use what's on
screen", on by default). Re-run this table once the fix lands; the "without"
column is the comparison.

Without these two clips' failure (their unbiased transcripts substituted), raw
WER over all clips is **5.1%** (12 errors in 235 words). The remaining errors
are:

- **email**: "priya.sharma at example.com" (3 errors).
- **numbers**: "3.30pm" for "3:30 p.m." (2 errors).
- **code-term**: "Fetch User Profile" (3 errors).
- **names**: "Notch voice", "test flight" (4 errors). "PropSoch" differs only in case, which WER ignores.

**WER final** adds the self-correction ("at 5, actually 6" is delivered as
said), which only a cleanup pass would fix.

## Where the time goes

- **Transcription is all of it.** Fit takes under 0.1 ms. Cleanup didn't run
  here; when Apple Intelligence is available, the app caps it at 400 ms.
- **Transcription has a ~0.7 s floor.** A linear fit over the 8 clips without
  custom words gives warm transcribe ≈ 677 ms + 58 ms per second of audio. The
  two empty decodes agree: 0.79 s and 0.97 s with no text emitted, against
  0.99 s and 1.18 s for a full decode of the same clips. That floor is the mel
  spectrogram and audio encoder, which run on a padded 30 s window no matter
  how short the clip. It dominates short dictations: a 2 s chat message waits
  0.84 s.
- **The per-second part matters only for long takes.** A 27 s paragraph waits
  2.3 s. Past 30 s, WhisperKit decodes window after window. The fit predicts
  ~4 s for 60 s and ~8 s for 120 s, but no fixture is that long, so those
  figures are untested.
- **Cold vs warm barely differs** once the model is loaded: the first
  dictation is ~150 ms slower than warm, and the other clips' first passes fall
  within warm noise.
- **Release vs Debug makes no visible difference.** A Debug smoke run the same
  day (1 warm pass) summed to 10.4 s of warm totals against 11.1 s here, which
  is within noise. CoreML on the Neural Engine does the work, not Swift code.

## Noise

Within this run, each clip's 5 warm transcribe times spread 15–25% from min to
max (for example, `email` 881–1122 ms). Compare warm medians, and treat a
difference under ~10% on a single clip as noise. All 6 passes produced the
same text for every clip.

## What couldn't run

- **Cleanup (both backends).** `SystemLanguageModel.default` reports
  `modelNotReady` on this macOS 27 beta, and Qwen3-4B (MLX) is not installed.
  The bench supports both, but that code path is **untested on a real model**.
  Cleanup latency, deadline misses and WER final after cleanup are unmeasured.
- **Bias prompt / custom words.** Broken, as described above.
- First-ever launch (Neural Engine compile), takes longer than 30 s, real
  voices and microphones, the AX read, and the paste.
