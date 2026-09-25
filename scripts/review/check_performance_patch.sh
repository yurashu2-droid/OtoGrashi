#!/usr/bin/env bash
# Portable checks; AVFoundation rendering and Flutter UI need the full iOS toolchain.
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v dart >/dev/null
command -v swiftc >/dev/null
command -v python3 >/dev/null
dart scripts/review/natural_golden_regression.dart
dart scripts/review/performance_regression.dart
dart scripts/review/performance_gestures.dart
dart scripts/review/performance_edges.dart
python3 scripts/review/check_performance_contract.py
bash scripts/review/run_natural_checks.sh
