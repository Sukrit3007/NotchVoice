#!/bin/sh
# Renders every clip in fixtures.json to Fixtures/<id>.wav with macOS `say`:
# 16 kHz mono 16-bit, the format the app records in.
#
# Synthetic on purpose: no one's voice is recorded or committed. The output
# is byte-identical for the same macOS, voice and rate. SHA256SUMS records the
# bytes, so a changed voice after an OS update shows up as a checksum failure
# rather than as an unexplained shift in the numbers. If it fails, regenerate
# the clips and record a new baseline; don't compare across the change.
#
#   Tools/Bench/make-fixtures.sh            # regenerate the clips
#   Tools/Bench/make-fixtures.sh --check    # only verify the committed clips
set -eu

here=$(cd "$(dirname "$0")" && pwd)
json="$here/fixtures.json"
out="$here/Fixtures"

if [ "${1:-}" = "--check" ]; then
    cd "$out" && shasum -a 256 -c SHA256SUMS
    exit
fi

field() { plutil -extract "$1" raw -o - "$json"; }

voice=$(field voice)
rate=$(field rate)
count=$(field fixtures)

mkdir -p "$out"
rm -f "$out"/*.wav "$out/SHA256SUMS"

i=0
while [ "$i" -lt "$count" ]; do
    id=$(field "fixtures.$i.id")
    text=$(field "fixtures.$i.say")
    say -v "$voice" -r "$rate" --file-format=WAVE --data-format=LEI16@16000 \
        -o "$out/$id.wav" "$text"
    seconds=$(afinfo "$out/$id.wav" | awk '/estimated duration/ { printf "%.1f", $3 }')
    echo "$id.wav  ${seconds}s"
    i=$((i + 1))
done

cd "$out" && shasum -a 256 ./*.wav > SHA256SUMS
du -sh "$out" | awk '{ print "total " $1 }'
