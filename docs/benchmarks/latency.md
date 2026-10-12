# Latency and accuracy baseline

Dictation pipeline, measured with `Tools/Bench/run.sh` (see `README.md` in this
folder). Raw output: `baseline-2026-10-13-m1pro-release.json`.

| | |
|---|---|
| Date | 2026-10-13 (IST) |
| Machine | MacBook Pro (MacBookPro18,3), Apple M1 Pro, 16 GB, on power |
| macOS | 27.0 (26A5425a, beta) |
| Toolchain | Xcode 27.0 (27A5228h), Swift 6.4 |
| Build | Release, commit `5551353` |
| Speech model | `openai_whisper-large-v3-v20240930_turbo_632MB` (the app's default, "Accurate"), argmax-oss-swift (WhisperKit) 1.1.1, language `en` |
| Cleanup | **None ran.** Apple Intelligence reports `modelNotReady` on this Mac, and the local Qwen model is not installed (deliberately not downloaded) |
| Runs | 1 cold pass + 5 warm passes (median), 10 clips, 77 s of audio |

## Launch

| Step | Time | How measured |
|---|--:|---|
| Hugging Face check in `prepare` (2 repo listings + 22 sequential HEAD requests) | ~6.1 s | **Estimate.** The same requests replayed with `curl` from this Mac: 0.7 s + 5.4 s. Measured with WhisperKit 0.18's download path; not timed inside the app |
| CoreML load + prewarm (`WhisperKitService.load(from:)`) | 4.8 s | Bench, CoreML cache warm |
| First dictation after the load (2.1 s clip) | 0.97 s | Bench. Warm median for the same clip is 0.79 s |

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
| chat-short | 2.1 | 973 | 791 | 2.7 | — | 0.01 | 791 | 0.0% | 0.0% |
| chat-question | 2.2 | 800 | 764 | 2.9 | — | 0.01 | 764 | 0.0% | 0.0% |
| self-correction | 4.1 | 868 | 849 | 4.8 | — | 0.03 | 849 | 0.0% | 22.2% |
| code-term (terms) | 3.8 | 1020 | 982 | 3.9 | — | 0.02 | 982 | 0.0% | 0.0% |
| email | 4.8 | 908 | 884 | 5.4 | — | 0.02 | 884 | 33.3% | 33.3% |
| names (terms) | 5.7 | 1281 | 1268 | 4.5 | — | 0.03 | 1268 | 0.0% | 0.0% |
| list | 6.7 | 1074 | 1054 | 6.4 | — | 0.03 | 1054 | 0.0% | 0.0% |
| numbers | 9.1 | 1110 | 1094 | 8.3 | — | 0.03 | 1094 | 8.7% | 8.7% |
| update-medium | 11.5 | 1270 | 1315 | 8.7 | — | 0.04 | 1315 | 0.0% | 0.0% |
| paragraph-long | 27.1 | 2207 | 2166 | 12.5 | — | 0.07 | 2166 | 0.0% | 0.0% |
| **All** | 77.1 | 11508 | 11166 | | | | 11166 | **2.1%** | **3.0%** |

The remaining raw errors are:

- **email**: "priya.sharma at example.com" (3 errors).
- **numbers**: "3.30pm" for "3:30 p.m." (2 errors).

**WER final** adds the self-correction ("at 5, actually 6" is delivered as
said), which only a cleanup pass would fix. WER ignores case. Note that the
email clip's cold transcript started in lower case ("please send…").

### Custom words (bias prompt)

| Clip | Terms | WER raw with | WER raw without | Transcribe warm with | without |
|---|---|--:|--:|--:|--:|
| code-term | fetchUserProfile | 0.0% | 25.0% | 982 | 901 |
| names | Priya, Propsoch, Arjun, NotchVoice, TestFlight | 0.0% | 25.0% | 1268 | 1013 |

The terms fix every error they cover: "Fetch User Profile", "Notch voice" and
"test flight". The prompt costs +81 ms for 1 term and +255 ms for 5 terms,
because WhisperKit decodes each prompt token in turn (roughly 12 ms per token,
by hotfix-bias's separate measurement). On-screen context goes through the same
prompt and, for a field of ~120 tokens, costs roughly +1.5 s. That figure is
also hotfix-bias's measurement; this bench does not cover screen context.

## Where the time goes

- **Transcription is all of it.** Fit takes under 0.1 ms. Cleanup didn't run
  here; when Apple Intelligence is available, the app caps it at 400 ms.
- **Transcription has a ~0.65 s floor.** A linear fit over the 8 clips without
  custom words gives warm transcribe ≈ 639 ms + 56 ms per second of audio. The
  floor is the mel spectrogram and audio encoder, which run on a padded 30 s
  window no matter how short the clip. It dominates short dictations: a 2 s
  chat message waits 0.79 s.
- **The per-second part matters only for long takes.** A 27 s paragraph waits
  2.2 s. Past 30 s, WhisperKit decodes window after window. The fit predicts
  ~4.0 s for 60 s and ~7.4 s for 120 s, but no fixture is that long, so those
  figures are untested.
- **The bias prompt is the other variable cost.** Each prompt token costs
  about as much as 0.2 s of audio.
- **Cold vs warm barely differs** once the model is loaded: the first
  dictation is ~180 ms slower than warm.
- **Release vs Debug makes no visible difference** (a Debug smoke run on
  2026-10-12 was within noise). CoreML on the Neural Engine does the work, not
  Swift code.

## Noise

Same machine, same code (WhisperKit 0.18, `45a04d7` → `5b51287`, which differ
only in prompted decodes). Between those two runs, an hour apart, warm medians
of the unprompted clips moved **6–13%**, all in the same direction. Within a
run, a clip's 5 warm times spread 2–14% (this run) to 15–25% (the first run)
from min to max.

Compare warm medians from runs made back to back in one session. Treat a
difference under ~15% on a single clip, or ~10% on the **All** row, as noise.
All 6 passes produced the same text for every clip.

## History

| Commit | WhisperKit | Unprompted warm sum (8 clips) | Raw WER | Note |
|---|---|--:|--:|---|
| `45a04d7` | 0.18.0 | 9 355 ms | 14.0% | Bias prompt broken: both term clips came back empty (`baseline-2026-10-12-m1pro-release.json`) |
| `5b51287` | 0.18.0 + filter workaround | 8 573 ms | 2.1% | Bias fixed by a logits filter; run not committed |
| `5551353` | 1.1.1 | 8 916 ms | 2.1% | This baseline. Upstream fix; filter removed |

The 0.18 → 1.1.1 change on the unprompted path (no prefill-cache model in 1.x)
is +4% against the run just before it, and −5% against the first run. That is
within run-to-run drift, so no cost from it is visible at this resolution.

## What couldn't run

- **Cleanup (both backends).** `SystemLanguageModel.default` reports
  `modelNotReady` on this macOS 27 beta, and Qwen3-4B (MLX) is not installed.
  The bench supports both, but that code path is **untested on a real model**.
  Cleanup latency, deadline misses and WER final after cleanup are unmeasured.
- **Screen context in the bias prompt.** The bench passes only custom words.
- First-ever launch (Neural Engine compile), takes longer than 30 s, real
  voices and microphones, the AX read, and the paste.
