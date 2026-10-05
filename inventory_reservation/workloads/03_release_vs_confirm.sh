#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
reset_state
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set +e
(psql_run -At <<'SQL' >"$TMP/release.out" 2>"$TMP/release.err"
SET deadlock_timeout = '50ms';
SET search_path = inventory_reservation, public;
SELECT * FROM release_reservation('release-race', 1003);
SQL
) & A=$!

(psql_run -At <<'SQL' >"$TMP/confirm.out" 2>"$TMP/confirm.err"
SET deadlock_timeout = '50ms';
SET search_path = inventory_reservation, public;
SELECT * FROM confirm_reservation('confirm-race', 1003);
SQL
) & B=$!

wait "$A"; RA=$?
wait "$B"; RB=$?
set -e

cat "$TMP/release.out" "$TMP/confirm.out"
if [[ $RA -ne 0 || $RB -ne 0 ]]; then
  cat "$TMP/release.err" "$TMP/confirm.err" >&2
  echo "03_release_vs_confirm: FAIL (one concurrent operation errored)" >&2
  exit 1
fi

psql_run -At <<'SQL'
SET search_path = inventory_reservation, public;
DO $$
DECLARE
  v_status TEXT;
  v_successes INTEGER;
BEGIN
  SELECT status INTO v_status FROM reservations WHERE reservation_id = 1003;
  IF v_status NOT IN ('released', 'confirmed') THEN
    RAISE EXCEPTION 'reservation 1003 ended in invalid status %', v_status;
  END IF;

  SELECT COUNT(*) INTO v_successes
  FROM operation_results
  WHERE operation_id IN ('release-race', 'confirm-race') AND success;

  IF v_successes <> 1 THEN
    RAISE EXCEPTION 'exactly one release/confirm operation must succeed';
  END IF;
END
$$;
SQL

assert_invariants
echo "03_release_vs_confirm: PASS"
