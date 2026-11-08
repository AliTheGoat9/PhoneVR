#!/usr/bin/env bash
# Runs the JVM tests for the pure-Kotlin core. Needs: kotlinc, java, ffmpeg (with libx265), g++, python3.
# Usage: KOTLINC=/path/to/kotlinc ./run_tests.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/../app/src/main/java/com/phonevr/core"
OUT="${TMPDIR:-/tmp}/phonevr-jvm-test"; mkdir -p "$OUT"
KOTLINC="${KOTLINC:-kotlinc}"

"$KOTLINC" -nowarn "$CORE/Protocol.kt" "$CORE/HevcRtpDepacketizer.kt" "$HERE/DepacketizerTest.kt" -include-runtime -d "$OUT/test.jar"

java -jar "$OUT/test.jar" rtp-ok   ffmpeg "$OUT"
java -jar "$OUT/test.jar" rtp-loss ffmpeg "$OUT"

# Cross-check against the real C++ driver code (UdpLink + protocol.h)
g++ -std=c++17 -I"$HERE/../../driver/src" "$HERE/../../driver/tests/test_link.cpp" -o "$OUT/test_link" -pthread
"$OUT/test_link" > "$OUT/test_link.out" 2>&1 &
CPP=$!
sleep 1
java -jar "$OUT/test.jar" proto ffmpeg "$OUT"
wait $CPP || true
echo "--- what the C++ driver code parsed:"; cat "$OUT/test_link.out"
