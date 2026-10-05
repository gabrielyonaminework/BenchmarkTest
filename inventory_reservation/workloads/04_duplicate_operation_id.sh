#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
reset_state
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set +e
(psql_run -At <<'SQL' >"$TMP/a.out" 2>"$TMP/a.err"
SET search_path = inventory_reservation, public;
SELECT * FROM reserve_stock('duplicate-op-1', 3, 10, 7);
SQL
) & A=$!

(psql_run -At <<'SQL' >"$TMP/b.out" 2>"$TMP/b.err"
SET search_path = inventory_reservation, public;
SELECT * FROM reserve_stock('duplicate-op-1', 3, 10, 7);
SQL
) & B=$!

wait "$A"; RA=$?
wait "$B"; RB=$?
set -e

if [[ $RA -ne 0 || $RB -ne 0 ]]; then
  cat "$TMP/a.err" "$TMP/b.err" >&2
  echo "04_duplicate_operation_id: FAIL (duplicate request raised a database error)" >&2
  exit 1
fi

A_OUT="$(tail -n 1 "$TMP/a.out")"
B_OUT="$(tail -n 1 "$TMP/b.out")"
printf '%s\n%s\n' "$A_OUT" "$B_OUT"

if [[ "$A_OUT" != "$B_OUT" ]]; then
  echo "04_duplicate_operation_id: FAIL (concurrent duplicates returned different logical results)" >&2
  exit 1
fi

psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
DO $$
DECLARE
  v_count INTEGER;
  v_reserved INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM reservations
  WHERE product_id = 3 AND warehouse_id = 10 AND quantity = 7 AND status = 'active';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'duplicate operation created % matching reservations', v_count;
  END IF;

  SELECT reserved INTO v_reserved FROM inventory WHERE product_id = 3 AND warehouse_id = 10;
  IF v_reserved <> 7 THEN
    RAISE EXCEPTION 'expected reserved=7 after duplicate request, got %', v_reserved;
  END IF;
END
$$;
SQL

assert_invariants
echo "04_duplicate_operation_id: PASS"
