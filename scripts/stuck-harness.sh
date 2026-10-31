#!/bin/bash
#
# Builds the replay harness from the real detector sources, then runs it.
# The traces live in stuck-harness/, outside the app target, so they can't
# reach the app. All results are about synthetic traces.
#
#   scripts/stuck-harness.sh evaluate
#   scripts/stuck-harness.sh evaluate --json /abs/results.json
#   scripts/stuck-harness.sh checks
#   scripts/stuck-harness.sh live-replay 30

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_BINARY="${CLICKY_STUCK_HARNESS_BINARY:-$(mktemp -d -t clicky-stuck-harness)/stuck-harness}"

swiftc -O -swift-version 5 \
    "$REPOSITORY_ROOT/leanring-buddy/StuckDetector.swift" \
    "$REPOSITORY_ROOT/leanring-buddy/StuckEventClassifier.swift" \
    "$REPOSITORY_ROOT/stuck-harness/TraceGenerators.swift" \
    "$REPOSITORY_ROOT/stuck-harness/main.swift" \
    -o "$HARNESS_BINARY"

exec "$HARNESS_BINARY" "$@"
