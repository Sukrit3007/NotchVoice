#!/bin/sh
# Runs the dictation bench (AppTests/DictationBench.swift) on this Mac and
# prints the markdown table. See docs/benchmarks/README.md.
#
#   Tools/Bench/run.sh
#   RUNS=10 Tools/Bench/run.sh               # warm passes (default 5)
#   CONFIG=Debug Tools/Bench/run.sh          # default Release, as shipped
#   MODEL=openai_whisper-base Tools/Bench/run.sh   # another installed model
#   OUT=/some/dir Tools/Bench/run.sh         # default build/bench/<timestamp>
#
# Uses the speech model the app already downloaded and never downloads one.
# Quit Notch Voice first if it is running: it shares the Neural Engine.
set -eu

cd "$(dirname "$0")/../.."
root=$(pwd)

config=${CONFIG:-Release}
runs=${RUNS:-5}
out=${OUT:-$root/build/bench/$(date +%Y%m%d-%H%M%S)}
derived=${DERIVED_DATA:-$root/build/bench-dd}
model=${MODEL:-$(defaults read com.sukrit.notchvoice speechModel 2>/dev/null \
    || echo openai_whisper-large-v3-v20240930_turbo_632MB)}

folder="$HOME/Library/Application Support/com.sukrit.notchvoice/Models/models/argmaxinc/whisperkit-coreml/$model"
if [ ! -d "$folder/AudioEncoder.mlmodelc" ]; then
    echo "SKIP: speech model $model is not installed at:"
    echo "  $folder"
    echo "Open Notch Voice once to download it. The bench never downloads."
    exit 0
fi

Tools/Bench/make-fixtures.sh --check >/dev/null || {
    echo "Fixture audio doesn't match Tools/Bench/Fixtures/SHA256SUMS." >&2
    echo "Regenerate with Tools/Bench/make-fixtures.sh and record a new baseline." >&2
    exit 1
}

# The Xcode project is generated and gitignored; it only knows this file once
# xcodegen has run since it was added.
if ! grep -q DictationBench.swift NotchVoice.xcodeproj/project.pbxproj 2>/dev/null; then
    if pgrep -xq Xcode; then
        echo "Quit Xcode, then run: xcodegen generate (it hangs xcodebuild with Xcode open)." >&2
        exit 1
    fi
    xcodegen generate --quiet
fi

if pgrep -xq "Notch Voice"; then
    echo "warning: Notch Voice is running; its model shares the Neural Engine with the bench." >&2
fi

mkdir -p "$out"
echo "Building ($config) and running; takes a few minutes. Log: $out/xcodebuild.log"

# TEST_RUNNER_<NAME> reaches the test process as <NAME>.
TEST_RUNNER_NOTCHVOICE_BENCH=1 \
TEST_RUNNER_NOTCHVOICE_BENCH_RUNS="$runs" \
TEST_RUNNER_NOTCHVOICE_BENCH_OUT="$out" \
TEST_RUNNER_NOTCHVOICE_BENCH_MODEL="$model" \
TEST_RUNNER_NOTCHVOICE_BENCH_COMMIT="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- App Core || echo '-dirty')" \
xcodebuild test \
    -scheme NotchVoice \
    -configuration "$config" \
    -derivedDataPath "$derived" \
    -skipPackagePluginValidation \
    -only-testing:NotchVoiceTests/DictationBench \
    ENABLE_TESTABILITY=YES \
    ONLY_ACTIVE_ARCH=YES \
    >"$out/xcodebuild.log" 2>&1 || {
        tail -30 "$out/xcodebuild.log" >&2
        echo "xcodebuild failed; full log: $out/xcodebuild.log" >&2
        exit 1
    }

if [ ! -f "$out/bench.md" ]; then
    grep -E "skipped|cancel" "$out/xcodebuild.log" | tail -5 >&2 || true
    echo "The bench did not write results; see $out/xcodebuild.log" >&2
    exit 1
fi

cat "$out/bench.md"
echo
echo "Results: $out/bench.md and $out/bench.json"
