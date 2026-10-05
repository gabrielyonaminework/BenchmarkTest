SET search_path = inventory_reservation, public;

INSERT INTO products(product_id, sku) VALUES
    (1, 'WIDGET-A'),
    (2, 'WIDGET-B'),
    (3, 'WIDGET-C');

INSERT INTO warehouses(warehouse_id, name) VALUES
    (10, 'North'),
    (20, 'South'),
    (30, 'East');

INSERT INTO inventory(product_id, warehouse_id, on_hand, reserved) VALUES
    (1, 10, 100, 10),
    (1, 20, 100, 10),
    (1, 30,  50,  0),
    (2, 10,  80, 20),
    (2, 20,  60,  0),
    (2, 30,  40,  0),
    (3, 10,  50,  0),
    (3, 20,  50,  0),
    (3, 30,  50,  0);

INSERT INTO reservations(reservation_id, product_id, warehouse_id, quantity, status) VALUES
    (1001, 1, 10, 10, 'active'),
    (1002, 1, 20, 10, 'active'),
    (1003, 2, 10, 20, 'active');

ALTER TABLE reservations ALTER COLUMN reservation_id RESTART WITH 2000;
