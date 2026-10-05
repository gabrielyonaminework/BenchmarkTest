#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
reset_state
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

(psql_run -At <<'SQL' >"$TMP/a.out" 2>"$TMP/a.err"
SET search_path = inventory_reservation, public;
SELECT * FROM reserve_stock('overlap-a', 2, 20, 40);
SQL
) & A=$!

(psql_run -At <<'SQL' >"$TMP/b.out" 2>"$TMP/b.err"
SET search_path = inventory_reservation, public;
SELECT * FROM reserve_stock('overlap-b', 2, 20, 40);
SQL
) & B=$!

wait "$A"
wait "$B"

cat "$TMP/a.out" "$TMP/b.out"

psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
DO $$
DECLARE
  v_successes INTEGER;
  v_failures INTEGER;
BEGIN
  SELECT COUNT(*) FILTER (WHERE success), COUNT(*) FILTER (WHERE NOT success)
  INTO v_successes, v_failures
  FROM operation_results
  WHERE operation_id IN ('overlap-a', 'overlap-b');

  IF v_successes <> 1 OR v_failures <> 1 THEN
    RAISE EXCEPTION 'expected one successful and one failed overlapping reservation';
  END IF;
END
$$;
SQL

assert_invariants
echo "01_overlapping_reservations: PASS"
