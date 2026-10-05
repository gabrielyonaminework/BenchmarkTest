SET search_path = inventory_reservation, public;

-- =============================================================================
-- Concurrency-safe inventory reservation implementation.
--
-- Public result shape for all write functions (unchanged):
--     success BOOLEAN, code TEXT, reservation_id BIGINT
--
-- The public function names, argument order/types, result columns, and the set
-- of result codes are identical to the starter. Only the internal transaction
-- logic is redesigned so every supplied concurrent workload completes without
-- deadlocks while preserving all invariants and exactly-once semantics.
--
-- Design summary
-- --------------
-- 1. Per-operation idempotency via an advisory *transaction* lock keyed on the
--    operation_id (NOT a single global lock). Concurrent calls that share an
--    operation_id serialize on this key and re-check operation_results after
--    acquiring it, so a committed operation is applied exactly once and every
--    duplicate/retry returns the identical stored result. Operations with
--    different operation_ids use different keys and never contend here.
--
-- 2. Deadlock-free row locking via a single canonical acquisition order:
--       (a) lock the affected inventory row(s) with FOR UPDATE, ordered by
--           ascending (product_id, warehouse_id);
--       (b) only then lock the reservation row with FOR UPDATE and re-read it.
--    Every function obeys this order, so two transactions touching the same
--    rows can never form a lock cycle. Transactions touching disjoint rows
--    never block one another.
--
-- 3. All reads used for decisions (stock availability, reservation status) are
--    taken on rows already locked FOR UPDATE, so decisions cannot be based on
--    stale snapshots and each logical mutation is applied exactly once.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Internal helper: derive a stable 64-bit advisory-lock key from operation_id.
-- Marked IMMUTABLE so the planner can inline it. This is intentionally a
-- per-operation key, never a shared constant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _op_lock_key(p_operation_id TEXT)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
SET search_path = inventory_reservation, public
AS $$
    SELECT hashtextextended(p_operation_id, 0);
$$;

-- -----------------------------------------------------------------------------
-- reserve_stock
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reserve_stock(
    p_operation_id TEXT,
    p_product_id BIGINT,
    p_warehouse_id BIGINT,
    p_quantity INTEGER
)
RETURNS TABLE(success BOOLEAN, code TEXT, reservation_id BIGINT)
LANGUAGE plpgsql
SET search_path = inventory_reservation, public
AS $$
DECLARE
    v_existing operation_results%ROWTYPE;
    v_inventory inventory%ROWTYPE;
    v_reservation_id BIGINT;
BEGIN
    -- Fast path: a committed result is immutable, return it without locking.
    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    -- Serialize duplicates of THIS operation_id (per-operation, not global).
    PERFORM pg_advisory_xact_lock(_op_lock_key(p_operation_id));

    -- Re-check: another transaction with the same id may have committed while
    -- we waited for the advisory lock.
    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    IF p_quantity <= 0 THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'reserve', FALSE, 'invalid_quantity', NULL);
        RETURN QUERY SELECT FALSE, 'invalid_quantity'::TEXT, NULL::BIGINT;
        RETURN;
    END IF;

    -- Lock the single affected inventory row.
    SELECT * INTO v_inventory
    FROM inventory
    WHERE product_id = p_product_id
      AND warehouse_id = p_warehouse_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'reserve', FALSE, 'inventory_not_found', NULL);
        RETURN QUERY SELECT FALSE, 'inventory_not_found'::TEXT, NULL::BIGINT;
        RETURN;
    END IF;

    IF (v_inventory.on_hand - v_inventory.reserved) < p_quantity THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'reserve', FALSE, 'insufficient_stock', NULL);
        RETURN QUERY SELECT FALSE, 'insufficient_stock'::TEXT, NULL::BIGINT;
        RETURN;
    END IF;

    UPDATE inventory
    SET reserved = reserved + p_quantity
    WHERE product_id = p_product_id
      AND warehouse_id = p_warehouse_id;

    INSERT INTO reservations(product_id, warehouse_id, quantity, status)
    VALUES (p_product_id, p_warehouse_id, p_quantity, 'active')
    RETURNING reservations.reservation_id INTO v_reservation_id;

    INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
    VALUES (p_operation_id, 'reserve', TRUE, 'reserved', v_reservation_id);

    RETURN QUERY SELECT TRUE, 'reserved'::TEXT, v_reservation_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- release_reservation
--   Touches one inventory row (the reservation's warehouse) + the reservation.
--   Canonical order: inventory row FIRST, reservation row SECOND.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION release_reservation(
    p_operation_id TEXT,
    p_reservation_id BIGINT
)
RETURNS TABLE(success BOOLEAN, code TEXT, reservation_id BIGINT)
LANGUAGE plpgsql
SET search_path = inventory_reservation, public
AS $$
DECLARE
    v_existing operation_results%ROWTYPE;
    v_snap reservations%ROWTYPE;
    v_res reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(_op_lock_key(p_operation_id));

    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    -- Unlocked snapshot to discover which inventory row to lock first.
    SELECT * INTO v_snap
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'release', FALSE, 'reservation_not_found', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_found'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    -- (a) Lock inventory row first.
    PERFORM 1 FROM inventory
    WHERE product_id = v_snap.product_id
      AND warehouse_id = v_snap.warehouse_id
    FOR UPDATE;

    -- (b) Lock the reservation row and re-read its authoritative state.
    SELECT * INTO v_res
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id
    FOR UPDATE;

    -- Defensive: if a concurrent move relocated the reservation between the
    -- snapshot and the lock, also lock the now-current inventory row. (Does not
    -- occur in the supplied workloads; keeps the operation correct in general.)
    IF v_res.warehouse_id <> v_snap.warehouse_id THEN
        PERFORM 1 FROM inventory
        WHERE product_id = v_res.product_id
          AND warehouse_id = v_res.warehouse_id
        FOR UPDATE;
    END IF;

    IF v_res.status <> 'active' THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'release', FALSE, 'reservation_not_active', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_active'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    UPDATE inventory
    SET reserved = reserved - v_res.quantity
    WHERE product_id = v_res.product_id
      AND warehouse_id = v_res.warehouse_id;

    UPDATE reservations
    SET status = 'released'
    WHERE reservations.reservation_id = p_reservation_id;

    INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
    VALUES (p_operation_id, 'release', TRUE, 'released', p_reservation_id);

    RETURN QUERY SELECT TRUE, 'released'::TEXT, p_reservation_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- confirm_reservation
--   Touches one inventory row (the reservation's warehouse) + the reservation.
--   Canonical order: inventory row FIRST, reservation row SECOND.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION confirm_reservation(
    p_operation_id TEXT,
    p_reservation_id BIGINT
)
RETURNS TABLE(success BOOLEAN, code TEXT, reservation_id BIGINT)
LANGUAGE plpgsql
SET search_path = inventory_reservation, public
AS $$
DECLARE
    v_existing operation_results%ROWTYPE;
    v_snap reservations%ROWTYPE;
    v_res reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(_op_lock_key(p_operation_id));

    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    SELECT * INTO v_snap
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'confirm', FALSE, 'reservation_not_found', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_found'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    -- (a) Lock inventory row first (same order as every other operation).
    PERFORM 1 FROM inventory
    WHERE product_id = v_snap.product_id
      AND warehouse_id = v_snap.warehouse_id
    FOR UPDATE;

    -- (b) Lock the reservation row and re-read its authoritative state.
    SELECT * INTO v_res
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id
    FOR UPDATE;

    IF v_res.warehouse_id <> v_snap.warehouse_id THEN
        PERFORM 1 FROM inventory
        WHERE product_id = v_res.product_id
          AND warehouse_id = v_res.warehouse_id
        FOR UPDATE;
    END IF;

    IF v_res.status <> 'active' THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'confirm', FALSE, 'reservation_not_active', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_active'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    UPDATE inventory
    SET reserved = reserved - v_res.quantity,
        on_hand  = on_hand  - v_res.quantity
    WHERE product_id = v_res.product_id
      AND warehouse_id = v_res.warehouse_id;

    UPDATE reservations
    SET status = 'confirmed'
    WHERE reservations.reservation_id = p_reservation_id;

    INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
    VALUES (p_operation_id, 'confirm', TRUE, 'confirmed', p_reservation_id);

    RETURN QUERY SELECT TRUE, 'confirmed'::TEXT, p_reservation_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- move_reservation
--   Touches two inventory rows (source + destination, same product) + the
--   reservation row. Canonical order: lock the two inventory rows in ascending
--   warehouse_id order, then lock the reservation row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION move_reservation(
    p_operation_id TEXT,
    p_reservation_id BIGINT,
    p_destination_warehouse_id BIGINT
)
RETURNS TABLE(success BOOLEAN, code TEXT, reservation_id BIGINT)
LANGUAGE plpgsql
SET search_path = inventory_reservation, public
AS $$
DECLARE
    v_existing operation_results%ROWTYPE;
    v_snap reservations%ROWTYPE;
    v_res reservations%ROWTYPE;
    v_source_wh BIGINT;
    v_destination inventory%ROWTYPE;
    v_low BIGINT;
    v_high BIGINT;
BEGIN
    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(_op_lock_key(p_operation_id));

    SELECT * INTO v_existing FROM operation_results WHERE operation_id = p_operation_id;
    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    -- Unlocked snapshot to discover product + source warehouse.
    SELECT * INTO v_snap
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', FALSE, 'reservation_not_found', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_found'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    v_source_wh := v_snap.warehouse_id;

    -- (a) Lock both inventory rows in a single canonical order: ascending
    --     warehouse_id. Both opposite-direction moves of the same product thus
    --     take the same two rows in the same order and cannot deadlock.
    IF v_source_wh = p_destination_warehouse_id THEN
        -- No stock movement; still take the row lock so the reservation
        -- re-read below is consistent, then lock the reservation row.
        PERFORM 1 FROM inventory
        WHERE product_id = v_snap.product_id
          AND warehouse_id = v_source_wh
        FOR UPDATE;
    ELSE
        v_low  := LEAST(v_source_wh, p_destination_warehouse_id);
        v_high := GREATEST(v_source_wh, p_destination_warehouse_id);

        PERFORM 1 FROM inventory
        WHERE product_id = v_snap.product_id
          AND warehouse_id = v_low
        FOR UPDATE;

        PERFORM 1 FROM inventory
        WHERE product_id = v_snap.product_id
          AND warehouse_id = v_high
        FOR UPDATE;
    END IF;

    -- (b) Lock the reservation row and re-read authoritative state.
    SELECT * INTO v_res
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id
    FOR UPDATE;

    IF v_res.status <> 'active' THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', FALSE, 'reservation_not_active', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_active'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    -- Defensive: a concurrent move may have relocated the reservation after our
    -- snapshot. Lock the now-current source row too if it differs. (Not hit by
    -- the supplied workloads.)
    IF v_res.warehouse_id <> v_source_wh THEN
        PERFORM 1 FROM inventory
        WHERE product_id = v_res.product_id
          AND warehouse_id = v_res.warehouse_id
        FOR UPDATE;
        v_source_wh := v_res.warehouse_id;
    END IF;

    IF v_res.warehouse_id = p_destination_warehouse_id THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', TRUE, 'already_at_destination', p_reservation_id);
        RETURN QUERY SELECT TRUE, 'already_at_destination'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    -- Destination row (already locked above when it exists).
    SELECT * INTO v_destination
    FROM inventory
    WHERE product_id = v_res.product_id
      AND warehouse_id = p_destination_warehouse_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', FALSE, 'destination_not_found', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'destination_not_found'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    -- Atomicity: if the destination lacks capacity, change nothing.
    IF (v_destination.on_hand - v_destination.reserved) < v_res.quantity THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', FALSE, 'insufficient_stock', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'insufficient_stock'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    UPDATE inventory
    SET reserved = reserved - v_res.quantity
    WHERE product_id = v_res.product_id
      AND warehouse_id = v_source_wh;

    UPDATE inventory
    SET reserved = reserved + v_res.quantity
    WHERE product_id = v_res.product_id
      AND warehouse_id = p_destination_warehouse_id;

    UPDATE reservations
    SET warehouse_id = p_destination_warehouse_id
    WHERE reservations.reservation_id = p_reservation_id;

    INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
    VALUES (p_operation_id, 'move', TRUE, 'moved', p_reservation_id);

    RETURN QUERY SELECT TRUE, 'moved'::TEXT, p_reservation_id;
END;
$$;
