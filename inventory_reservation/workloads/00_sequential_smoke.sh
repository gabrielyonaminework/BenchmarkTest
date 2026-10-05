#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
reset_state

psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
SELECT * FROM reserve_stock('seq-reserve', 3, 10, 5);
SELECT * FROM release_reservation('seq-release', 1001);
SELECT * FROM confirm_reservation('seq-confirm', 1003);
SELECT * FROM move_reservation('seq-move', 1002, 30);
SQL

assert_invariants
echo "00_sequential_smoke: PASS"
