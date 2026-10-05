#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
reset_state
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

(psql_run -At <<'SQL' >"$TMP/holder.out" 2>"$TMP/holder.err"
SET search_path = inventory_reservation, public;
BEGIN;
SELECT * FROM reserve_stock('held-operation', 1, 30, 1);
SELECT pg_sleep(2.0);
COMMIT;
SQL
) & HOLDER=$!

sleep 0.25
START_MS="$(date +%s%3N)"
psql_run -At <<'SQL' >"$TMP/unrelated.out"
SET statement_timeout = '1500ms';
SET search_path = inventory_reservation, public;
SELECT * FROM reserve_stock('unrelated-operation', 3, 30, 1);
SQL
END_MS="$(date +%s%3N)"
ELAPSED=$((END_MS - START_MS))

wait "$HOLDER"
cat "$TMP/holder.out" "$TMP/unrelated.out"

if (( ELAPSED >= 1500 )); then
  echo "06_disjoint_progress: FAIL (unrelated operation took ${ELAPSED}ms)" >&2
  exit 1
fi

assert_invariants
echo "06_disjoint_progress: PASS (${ELAPSED}ms)"
