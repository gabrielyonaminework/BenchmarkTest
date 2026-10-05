#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
reset_state
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set +e
(psql_run -At <<'SQL' >"$TMP/a.out" 2>"$TMP/a.err"
SET deadlock_timeout = '50ms';
SET search_path = inventory_reservation, public;
SELECT * FROM move_reservation('move-a-to-b', 1001, 20);
SQL
) & A=$!

(psql_run -At <<'SQL' >"$TMP/b.out" 2>"$TMP/b.err"
SET deadlock_timeout = '50ms';
SET search_path = inventory_reservation, public;
SELECT * FROM move_reservation('move-b-to-a', 1002, 10);
SQL
) & B=$!

wait "$A"; RA=$?
wait "$B"; RB=$?
set -e

cat "$TMP/a.out" "$TMP/b.out"
if [[ $RA -ne 0 || $RB -ne 0 ]]; then
  cat "$TMP/a.err" "$TMP/b.err" >&2
  echo "02_opposite_moves: FAIL (a concurrent move errored; starter commonly deadlocks here)" >&2
  exit 1
fi

psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
DO $$
BEGIN
  IF (SELECT warehouse_id FROM reservations WHERE reservation_id = 1001) <> 20 THEN
    RAISE EXCEPTION 'reservation 1001 did not move to warehouse 20';
  END IF;
  IF (SELECT warehouse_id FROM reservations WHERE reservation_id = 1002) <> 10 THEN
    RAISE EXCEPTION 'reservation 1002 did not move to warehouse 10';
  END IF;
END
$$;
SQL

assert_invariants
echo "02_opposite_moves: PASS"
