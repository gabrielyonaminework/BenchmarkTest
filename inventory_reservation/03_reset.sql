SET search_path = inventory_reservation, public;

TRUNCATE TABLE operation_results, reservations, inventory, warehouses, products RESTART IDENTITY CASCADE;

\ir 01_seed.sql
