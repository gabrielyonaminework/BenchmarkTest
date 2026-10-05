# Inventory Reservation Task Data

This directory contains the supplied PostgreSQL schema, seed data, starter implementation, and deterministic concurrency workloads for the inventory reservation repair task.

## Files

- `00_schema.sql` — tables, constraints, indexes, and operation-result storage.
- `01_seed.sql` — deterministic products, warehouses, inventory rows, and active reservations.
- `02_starter_implementation.sql` — the existing public SQL implementation. It is correct for sequential execution but is not safe for all supplied concurrent workloads.
- `03_reset.sql` — restores the deterministic seed state after the schema has been created.
- `bootstrap_starter.sql` — loads the schema, seed data, and starter implementation.
- `workloads/` — concurrent scenarios used to reproduce the failures and validate behavior.

## Public SQL interfaces

All functions return exactly three columns:

`success BOOLEAN, code TEXT, reservation_id BIGINT`

The public functions are:

```sql
reserve_stock(operation_id TEXT, product_id BIGINT, warehouse_id BIGINT, quantity INTEGER)
release_reservation(operation_id TEXT, reservation_id BIGINT)
confirm_reservation(operation_id TEXT, reservation_id BIGINT)
move_reservation(operation_id TEXT, reservation_id BIGINT, destination_warehouse_id BIGINT)
```

Their names, argument order/types, and three-column result format are part of the task interface and must be preserved.

## Loading the starter state

From this directory, against the task database:

```bash
psql -v ON_ERROR_STOP=1 -d inventory_reservation -f bootstrap_starter.sql
```

The workload scripts honor `DATABASE_URL` when set; otherwise they connect to `${DB_NAME:-inventory_reservation}` using the normal PostgreSQL environment variables (`PGHOST`, `PGPORT`, `PGUSER`, and `PGPASSWORD`).

Run individual workloads from `workloads/`, or run `workloads/run_all.sh` after loading an implementation.
