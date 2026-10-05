#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

for test in \
  00_sequential_smoke.sh \
  01_overlapping_reservations.sh \
  02_opposite_moves.sh \
  03_release_vs_confirm.sh \
  04_duplicate_operation_id.sh \
  05_rollback_retry.sh \
  06_disjoint_progress.sh; do
  echo "==> $test"
  bash "$DIR/$test"
done

echo "All supplied workloads passed."
