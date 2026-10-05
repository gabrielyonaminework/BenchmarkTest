#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
reset_state

psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
BEGIN;
SELECT * FROM reserve_stock('rollback-op-1', 3, 20, 6);
ROLLBACK;
SQL

RESULT="$(psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
SELECT * FROM reserve_stock('rollback-op-1', 3, 20, 6);
SQL
)"
printf '%s\n' "$RESULT"

psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
DO $$
DECLARE
  v_count INTEGER;
  v_reserved INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM reservations
  WHERE product_id = 3 AND warehouse_id = 20 AND quantity = 6 AND status = 'active';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'rollback/retry produced % matching active reservations', v_count;
  END IF;

  SELECT reserved INTO v_reserved FROM inventory WHERE product_id = 3 AND warehouse_id = 20;
  IF v_reserved <> 6 THEN
    RAISE EXCEPTION 'expected reserved=6 after retry, got %', v_reserved;
  END IF;
END
$$;
SQL

assert_invariants
echo "05_rollback_retry: PASS"
