SET search_path = inventory_reservation, public;

-- Public result shape for all write functions:
--   success BOOLEAN, code TEXT, reservation_id BIGINT
--
-- The starter implementation is intentionally only sequentially safe.

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
    SELECT * INTO v_existing
    FROM operation_results
    WHERE operation_id = p_operation_id;

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
    v_res reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_existing
    FROM operation_results
    WHERE operation_id = p_operation_id;

    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    SELECT * INTO v_res
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'release', FALSE, 'reservation_not_found', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_found'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    IF v_res.status <> 'active' THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'release', FALSE, 'reservation_not_active', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_active'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    -- Existing work performed while holding the reservation lock widens the
    -- window in which the inconsistent lock order can be observed.
    PERFORM pg_sleep(0.08);

    PERFORM 1
    FROM inventory
    WHERE product_id = v_res.product_id
      AND warehouse_id = v_res.warehouse_id
    FOR UPDATE;

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
    v_snapshot reservations%ROWTYPE;
    v_res reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_existing
    FROM operation_results
    WHERE operation_id = p_operation_id;

    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    -- Read first so this path can lock inventory before the reservation row.
    SELECT * INTO v_snapshot
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'confirm', FALSE, 'reservation_not_found', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_found'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    PERFORM 1
    FROM inventory
    WHERE product_id = v_snapshot.product_id
      AND warehouse_id = v_snapshot.warehouse_id
    FOR UPDATE;

    PERFORM pg_sleep(0.08);

    SELECT * INTO v_res
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id
    FOR UPDATE;

    IF v_res.status <> 'active' THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'confirm', FALSE, 'reservation_not_active', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_active'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    UPDATE inventory
    SET reserved = reserved - v_res.quantity,
        on_hand = on_hand - v_res.quantity
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
    v_res reservations%ROWTYPE;
    v_destination inventory%ROWTYPE;
BEGIN
    SELECT * INTO v_existing
    FROM operation_results
    WHERE operation_id = p_operation_id;

    IF FOUND THEN
        RETURN QUERY SELECT v_existing.success, v_existing.code, v_existing.reservation_id;
        RETURN;
    END IF;

    SELECT * INTO v_res
    FROM reservations
    WHERE reservations.reservation_id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', FALSE, 'reservation_not_found', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_found'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    IF v_res.status <> 'active' THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', FALSE, 'reservation_not_active', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'reservation_not_active'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    IF v_res.warehouse_id = p_destination_warehouse_id THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', TRUE, 'already_at_destination', p_reservation_id);
        RETURN QUERY SELECT TRUE, 'already_at_destination'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    -- Locks are taken source first, destination second. Opposite-direction
    -- moves therefore take the same two inventory rows in opposite orders.
    PERFORM 1
    FROM inventory
    WHERE product_id = v_res.product_id
      AND warehouse_id = v_res.warehouse_id
    FOR UPDATE;

    PERFORM pg_sleep(0.08);

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

    IF (v_destination.on_hand - v_destination.reserved) < v_res.quantity THEN
        INSERT INTO operation_results(operation_id, operation_name, success, code, reservation_id)
        VALUES (p_operation_id, 'move', FALSE, 'insufficient_stock', p_reservation_id);
        RETURN QUERY SELECT FALSE, 'insufficient_stock'::TEXT, p_reservation_id;
        RETURN;
    END IF;

    UPDATE inventory
    SET reserved = reserved - v_res.quantity
    WHERE product_id = v_res.product_id
      AND warehouse_id = v_res.warehouse_id;

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
