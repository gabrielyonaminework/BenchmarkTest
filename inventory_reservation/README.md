# Inventory Reservation System (concurrency-safe)

This directory contains a PostgreSQL inventory reservation system that manages
stock across multiple warehouses. The four public procedures reserve stock,
release reservations, move active reservations between warehouses, and confirm
fulfilled reservations.

The original starter implementation was correct only for sequential execution
and deadlocked under concurrency because it locked rows in inconsistent orders.
This solution redesigns the transaction logic so **all supplied concurrency
workloads complete without deadlocks**, while preserving the public SQL
interfaces, the result codes, and every stated invariant.

## Quick start

From this directory, with PostgreSQL 14+ installed:

```bash
./run.sh
```

`run.sh` initializes a **clean** local PostgreSQL environment from scratch,
applies the completed implementation, and then runs every supplied concurrency
workload to validate it. It is fully offline and self-contained.

What it does:

1. Creates a fresh data directory with `initdb` (clean state on every run).
2. Starts a local server on a private port/socket.
3. Creates the `inventory_reservation` database.
4. Loads the schema, deterministic seed, and the fixed implementation
   (`bootstrap.sql`).
5. Runs `workloads/run_all.sh`.

Useful environment overrides (all optional):

| Variable         | Default                                            | Meaning                              |
|------------------|----------------------------------------------------|--------------------------------------|
| `INV_PGDATA`     | `/var/lib/postgresql/inventory_reservation_pgdata` | data directory                       |
| `INV_PGPORT`     | `54329`                                             | server port                          |
| `INV_SOCKET_DIR` | `/tmp/inv_pg_sock`                                  | unix socket directory                |
| `DB_NAME`        | `inventory_reservation`                             | database name                        |
| `RUN_WORKLOADS`  | `1`                                                 | set `0` to skip the workload run     |
| `KEEP_RUNNING`   | `1`                                                 | set `0` to stop the server on exit   |

After `run.sh` finishes, the server stays up (by default) and prints a `psql`
connection line you can use directly.

## Files

| File                            | Purpose                                                             |
|---------------------------------|---------------------------------------------------------------------|
| `00_schema.sql`                 | Tables, constraints, indexes, and operation-result storage (supplied, unchanged). |
| `01_seed.sql`                   | Deterministic products, warehouses, inventory, and active reservations (supplied, unchanged). |
| `02_implementation.sql`         | **The concurrency-safe implementation (the solution).**             |
| `02_starter_implementation.sql` | The original sequential-only starter, kept for reference. Not loaded by `run.sh`. |
| `03_reset.sql`                  | Restores the deterministic seed state (supplied, unchanged).        |
| `bootstrap.sql`                 | Loads schema + seed + the fixed implementation.                     |
| `bootstrap_starter.sql`         | Loads schema + seed + the original starter (supplied, for comparison). |
| `run.sh`                        | Clean init + apply + validate.                                      |
| `workloads/`                    | Deterministic concurrency scenarios.                                |

## Public SQL interfaces (unchanged)

All functions return exactly three columns: `success BOOLEAN, code TEXT,
reservation_id BIGINT`.

```sql
reserve_stock(operation_id TEXT, product_id BIGINT, warehouse_id BIGINT, quantity INTEGER)
release_reservation(operation_id TEXT, reservation_id BIGINT)
confirm_reservation(operation_id TEXT, reservation_id BIGINT)
move_reservation(operation_id TEXT, reservation_id BIGINT, destination_warehouse_id BIGINT)
```

Names, argument order/types, the three-column result shape, and the set of
result codes are identical to the starter and are part of the task interface.

## Invariants guaranteed

* `available = on_hand - reserved` (derived; never stored inconsistently).
* `on_hand >= reserved >= 0` (enforced by table `CHECK` constraints and by the
  logic, which never over-releases or over-reserves).
* The sum of `active` reservation quantities for a `(product, warehouse)` always
  equals that inventory row's `reserved`.
* Reserve / release / confirm each change stock exactly once.
* `move` is atomic: if the destination lacks available stock, nothing changes.

## Idempotency / exactly-once semantics

Every write carries an `operation_id`, recorded in `operation_results` when the
operation commits. The implementation guarantees:

* A committed operation affects state only once.
* A retry (same `operation_id`) returns the identical stored result without
  re-applying any change.
* Concurrent duplicates never create duplicate reservations or double stock
  updates — exactly one applies, the rest observe and return its result.
* A rolled-back attempt leaves no trace, so a later retry with the same
  `operation_id` still succeeds.
* A committed result (success *or* failure) is stable and returned verbatim on
  all future calls.

## How deadlocks are prevented (design)

Two independent mechanisms, neither of which globally serializes the system:

### 1. Per-operation idempotency lock (not global)

Before doing work, each function takes `pg_advisory_xact_lock` on a key derived
from the **`operation_id`** (`hashtextextended(operation_id, 0)`), then
re-checks `operation_results`:

* Calls that share an `operation_id` serialize on this key, so duplicates and
  concurrent retries collapse to a single applied effect and all return the same
  committed result.
* Calls with **different** `operation_id`s hash to different keys and never
  contend here — unrelated work proceeds in parallel.
* The lock is transaction-scoped, so a rollback releases it immediately and
  frees later retries.

This is deliberately **not** one global advisory lock; it is one lock *per
operation id*.

### 2. Canonical lock-acquisition order (deadlock-free)

All row locks are taken in one fixed order in every function:

1. Lock the affected **inventory row(s)** with `FOR UPDATE`, ordered by
   ascending `(product_id, warehouse_id)`.
2. Only then lock the **reservation row** with `FOR UPDATE`, and re-read its
   authoritative state.

Because every transaction acquires the same resources in the same order, no two
transactions can form a lock cycle:

* **Opposite-direction moves** of the same product lock the two inventory rows
  in ascending warehouse order in *both* directions, so they queue instead of
  deadlocking.
* **Release vs. confirm** on the same reservation both lock the inventory row
  before the reservation row, so one wins and the other observes the updated
  status and fails cleanly (`reservation_not_active`).

Decisions (stock availability, reservation status) are always read from rows
already locked `FOR UPDATE`, never from stale snapshots, so each logical
operation is applied exactly once.

Transactions touching disjoint inventory rows and distinct `operation_id`s never
block each other — a transaction paused mid-work (before commit) holding one
row's lock does not delay operations on unrelated rows.

## Running workloads manually

After loading an implementation (e.g. via `run.sh` or `bootstrap.sql`), point
the normal PostgreSQL environment at the running server and run the workloads:

```bash
export PGHOST=/tmp/inv_pg_sock PGPORT=54329 PGUSER=postgres DB_NAME=inventory_reservation
bash workloads/run_all.sh
# or an individual scenario:
bash workloads/02_opposite_moves.sh
```

The workload scripts honor `DATABASE_URL` when set; otherwise they connect to
`${DB_NAME:-inventory_reservation}` using the standard `PGHOST`, `PGPORT`,
`PGUSER`, and `PGPASSWORD` variables.

### Workload scenarios

| Script                              | Exercises                                                        |
|-------------------------------------|------------------------------------------------------------------|
| `00_sequential_smoke.sh`            | Basic sequential correctness of all four operations.             |
| `01_overlapping_reservations.sh`    | Two reservations racing for the same stock — exactly one wins.   |
| `02_opposite_moves.sh`              | Opposite-direction moves (the classic deadlock case).            |
| `03_release_vs_confirm.sh`          | Concurrent release and confirm of the same reservation.          |
| `04_duplicate_operation_id.sh`      | Concurrent duplicate `operation_id` requests (idempotency).      |
| `05_rollback_retry.sh`              | Retry after an explicit rollback.                                |
| `06_disjoint_progress.sh`           | Unrelated operation must not block behind a paused transaction.  |
