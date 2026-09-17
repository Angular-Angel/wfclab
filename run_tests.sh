#!/bin/bash
# run_tests.sh — headless test runner for Inheritors of Elyrion
#
# Prerequisites:
#   1. gdUnit4 addon installed in addons/gdUnit4/
#   2. Godot 4.7 binary at the path below (or set GODOT_BINARY env var)
#
# Usage:
#   ./run_tests.sh              # Run all tests
#   ./run_tests.sh -a tests/    # Run all tests (explicit directory)
#   ./run_tests.sh tests/test_swap_behavior.gd  # Run a single test file
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
#   2 — prerequisites not met (Godot binary not found, gdUnit4 not installed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_BINARY="${GODOT_BINARY:-/home/Angle/Documents/Programming/GodotEngine/Godot_v4.7.1-stable_linux.x86_64}"
TEST_DIR="${1:-tests/}"

# -- Prerequisite checks --
if [ ! -f "$GODOT_BINARY" ]; then
    echo "ERROR: Godot binary not found at '$GODOT_BINARY'"
    echo "Set GODOT_BINARY environment variable to the correct path."
    exit 2
fi

if [ ! -d "$SCRIPT_DIR/addons/gdUnit4" ]; then
    echo "ERROR: gdUnit4 addon not found at addons/gdUnit4/"
    echo "Install the gdUnit4 plugin from the Godot Asset Library first."
    exit 2
fi

# -- Run tests --
echo "Running gdUnit4 tests: $TEST_DIR"
cd "$SCRIPT_DIR"

# gdUnit4 headless execution via GdUnitCmdTool
#   --headless           : no window
#   -s <script>          : run the gdUnit4 CLI tool
#   -a <test_dir>        : scan this directory for test suites
"$GODOT_BINARY" --headless \
    -s addons/gdUnit4/bin/GdUnitCmdTool.gd \
    --ignoreHeadlessMode \
    -a "$TEST_DIR"

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "All tests passed."
else
    echo "One or more tests failed (exit code: $EXIT_CODE)."
fi
exit $EXIT_CODE
