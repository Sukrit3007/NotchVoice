# Benchmarks

How fast and how accurately the dictation pipeline turns audio into text on
this Mac. Recorded baselines live next to this file: `latency.md` is the latest
summary, and each `baseline-*.json` is the raw output of one run.

## Run it

```sh
Tools/Bench/run.sh                 # Release build, 1 cold + 5 warm passes
RUNS=10 Tools/Bench/run.sh         # more warm passes
CONFIG=Debug Tools/Bench/run.sh    # the build you run from Xcode
MODEL=openai_whisper-base Tools/Bench/run.sh   # another installed model
```

It prints a markdown table and writes `bench.md` + `bench.json` to
`build/bench/<timestamp>/` (gitignored). The first Release run builds every
package from scratch into `build/bench-dd`, which takes about 10 minutes. After
that, a run takes about 2 minutes.

Before you run it:

- **The speech model must already be installed.** Open Notch Voice once. The
  bench never downloads: with no model it prints `SKIP: …` and exits 0.
- **Quit Notch Voice.** It shares the Neural Engine, and the script warns if
  it's running.
- **Quit Xcode** if the script needs to regenerate the project. The `.xcodeproj`
  is generated, and `xcodegen` with Xcode open hangs `xcodebuild`. The script
  says when.
- Keep the Mac on power and otherwise idle. Thermal state shows up in the numbers.

## What it runs

`AppTests/DictationBench.swift`: a Swift Testing test hosted in the app and
switched off unless `NOTCHVOICE_BENCH=1`. `run.sh` sets that through
`TEST_RUNNER_NOTCHVOICE_BENCH`.

It is a test and not a command-line tool on purpose. Inside the app process it
uses the app's own code, its Application Support model folder, its defaults
(chosen model, cleanup preference), and CoreML's compile cache, which is kept
per bundle ID (`~/Library/Caches/com.sukrit.notchvoice/com.apple.e5rt.e5bundlecache`).
A separate binary would recompile the model for the Neural Engine from scratch.
That takes minutes to hours, and the result would say nothing about the app.

For each clip it runs the steps `DictationCoordinator` runs after key-up:

1. **Transcribe**: `WhisperKitService.transcribe`, language `en`. The clip's
   `terms` go in as the bias prompt through `BiasPrompt.build`, as the user's
   custom words would.
2. **Clean up**: every backend that can run here. That is Apple Intelligence
   (`AppleIntelligencePolish`) if it is available, and the local Qwen model
   (`LocalModelPolish`) if it is installed. The Qwen model is loaded up front,
   as at launch. Each backend is timed **without** its deadline. The app's rules
   (400 ms or 20 s deadline, echo and plausibility guards) are then applied to
   decide what would have been delivered. Only the backend the app would pick
   with the current settings counts toward the total. Nothing is downloaded.
3. **Fit**: `InsertionRules.fit` into an empty field, using the real
   `LowercaseWords` spell check.

The sequence is: model load (`WhisperKitService.load(from:)`, CoreML load +
prewarm), then a **cold** pass over every clip, then **N warm** passes. Clips
that have `terms` also get N extra transcriptions without them.

Not measured: recording, the key-down Accessibility read, reading the
dictionary from the store, corrections and snippets (there is no store here),
the paste (an 80 ms settle plus up to 250 ms waiting for the target to read
it), and the Hugging Face check that `prepare` makes before loading.

## Reading the numbers

| Column | Meaning |
|---|---|
| Model load + prewarm | One per process, like an app launch with the CoreML cache already warm. It is not a first-ever launch: that compiles for the Neural Engine and takes minutes to hours (see `docs/benchmarks/latency.md`). |
| Transcribe cold | The clip's first pass after the load. Only the first clip is cold in the strict sense. |
| Transcribe warm | Median over N passes. |
| ×RT | Audio seconds per second of warm transcription. Higher is faster. |
| Cleanup cold/warm | How long the app would wait for the backend it picks: the backend's time, capped at its deadline. `—` means no backend can run. |
| Fit | `InsertionRules`, in ms. |
| Total | Transcribe + cleanup wait + fit. This is the wait between key-up and the text being ready to paste. |
| WER raw | Raw transcript of the cold run vs the clip's `verbatim` text (or `expected` if there is none). |
| WER final | Delivered text vs `expected`. |

WER is the number of word substitutions, deletions and insertions divided by
the number of reference words. It is pooled over clips in the **All** row.
Formatting that keeps the words is not counted: case, punctuation, "five"/"5",
"1,250"/"1250", "p.m."/"PM", "14th"/"14", and fillers. Formatting that changes
the words is counted: "Notch voice" for "NotchVoice", or an email address
spelled out. `WordErrorRateTests` in the same file pins these rules.

The "Cleanup: <backend>, without its deadline" table shows how often a backend
misses the deadline the app gives it. The "Custom words" table shows WER and
time with and without the bias prompt.

## Fixtures

`Tools/Bench/fixtures.json` defines each clip:

- `id`: the clip's name.
- `say`: the text given to the voice. Write it the way a person would say it,
  for example "priya dot sharma at example dot com".
- `expected`: what should land in the document.
- `verbatim` (optional): the words actually said, when cleanup is expected to
  change them (a self-correction).
- `terms` (optional): custom words, used as the bias prompt.

`Tools/Bench/make-fixtures.sh` renders them with `say` (voice and rate are in
the JSON) to 16 kHz mono 16-bit WAV in `Tools/Bench/Fixtures/`, and records
`SHA256SUMS`. The audio is synthetic, so no one's voice is involved. It is
byte-identical on the same macOS and voice, which is why the clips are
committed (2.4 MB).

To add a clip: add it to the JSON, run `make-fixtures.sh`, commit the WAV,
`SHA256SUMS` and the JSON, then record a new baseline. Numbers from different
fixture sets aren't comparable.

`run.sh` runs `make-fixtures.sh --check` first. If it fails, the committed
audio no longer matches the checksums. Regenerate it, and record a new baseline
instead of comparing against the old one. A macOS update that changes the voice
shows up this way too: the regenerated checksums will differ from the ones in
git.

## Recording a baseline

1. Commit first, so the report shows a clean hash. `-dirty` means `App/` or
   `Core/` had uncommitted changes.
2. Run `Tools/Bench/run.sh`.
3. Copy `bench.json` to `docs/benchmarks/baseline-<date>.json`, and update
   `latency.md` with the machine, OS, model, date and table, plus anything that
   couldn't run.

Compare against a baseline only from the same machine, configuration and
fixture set, and preferably from a run made back to back in the same session.
Medians drifted 6–13% between two runs of identical code an hour apart
(`latency.md`, Noise). Treat a difference under ~15% on a single clip, or ~10%
on the **All** row, as noise.

## Environment variables

`run.sh` passes each of these as `TEST_RUNNER_<NAME>`, which `xcodebuild`
delivers to the test process as `<NAME>`:

| Variable | Default | |
|---|---|---|
| `NOTCHVOICE_BENCH` | unset | `1` switches the test on |
| `NOTCHVOICE_BENCH_RUNS` | 5 | Warm passes |
| `NOTCHVOICE_BENCH_OUT` | `build/bench` | Output directory |
| `NOTCHVOICE_BENCH_MODEL` | the app's chosen model | Speech model variant |
| `NOTCHVOICE_BENCH_COMMIT` | `unknown` | Shown in the report |
