#!/usr/bin/env bash
set -euo pipefail

WORKLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$(cd "$WORKLOAD_DIR/.." && pwd)"

psql_run() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 "$@"
  else
    psql -X -v ON_ERROR_STOP=1 -d "${DB_NAME:-inventory_reservation}" "$@"
  fi
}

reset_state() {
  (cd "$DATA_DIR" && psql_run -f 03_reset.sql >/dev/null)
}

assert_invariants() {
  psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM inventory
    WHERE on_hand < 0 OR reserved < 0 OR reserved > on_hand
  ) THEN
    RAISE EXCEPTION 'inventory numeric invariant violated';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM inventory i
    LEFT JOIN (
      SELECT product_id, warehouse_id, SUM(quantity)::INTEGER AS active_qty
      FROM reservations
      WHERE status = 'active'
      GROUP BY product_id, warehouse_id
    ) r USING (product_id, warehouse_id)
    WHERE i.reserved <> COALESCE(r.active_qty, 0)
  ) THEN
    RAISE EXCEPTION 'active reservation total does not equal inventory.reserved';
  END IF;
END
$$;
SQL
}
