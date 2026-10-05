#!/usr/bin/env bash
# =============================================================================
# run.sh — initialize a clean local PostgreSQL environment and apply the
#          concurrency-safe inventory reservation implementation.
#
# This script is fully self-contained and offline. It:
#   1. Creates a fresh PostgreSQL data directory with initdb (clean state).
#   2. Starts a local server on a private socket + port.
#   3. Creates the task database.
#   4. Loads the schema, deterministic seed, and the fixed implementation.
#   5. (Default) runs every supplied concurrency workload to validate.
#
# Re-running it always starts from a clean state: the data directory is
# recreated from scratch each time.
#
# Environment overrides (all optional):
#   INV_PGDATA      data directory               (default below)
#   INV_PGPORT      server port                  (default 54329)
#   INV_SOCKET_DIR  unix socket directory        (default /tmp/inv_pg_sock)
#   DB_NAME         database name                (default inventory_reservation)
#   RUN_WORKLOADS   "1" to run workloads, "0" to skip   (default 1)
#   KEEP_RUNNING    "1" to leave the server running on exit (default 1)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_NAME="${DB_NAME:-inventory_reservation}"
INV_PGPORT="${INV_PGPORT:-54329}"
INV_SOCKET_DIR="${INV_SOCKET_DIR:-/tmp/inv_pg_sock}"
INV_PGDATA="${INV_PGDATA:-/var/lib/postgresql/inventory_reservation_pgdata}"
RUN_WORKLOADS="${RUN_WORKLOADS:-1}"
KEEP_RUNNING="${KEEP_RUNNING:-1}"

# ---------------------------------------------------------------------------
# Locate the PostgreSQL server binaries (postgres/initdb/pg_ctl live in a
# versioned libexec dir on Debian/Ubuntu, not necessarily on PATH).
# ---------------------------------------------------------------------------
find_pgbin() {
  local candidate
  for candidate in \
    "$(pg_config --bindir 2>/dev/null || true)" \
    /usr/lib/postgresql/*/bin \
    /usr/pgsql-*/bin \
    /usr/local/pgsql/bin ; do
    if [[ -n "$candidate" && -x "$candidate/initdb" && -x "$candidate/pg_ctl" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  # Fall back to PATH if initdb is directly available.
  if command -v initdb >/dev/null 2>&1 && command -v pg_ctl >/dev/null 2>&1; then
    dirname "$(command -v initdb)"
    return 0
  fi
  echo "ERROR: could not locate PostgreSQL server binaries (initdb/pg_ctl)." >&2
  exit 1
}

PGBIN="$(find_pgbin)"
echo "Using PostgreSQL binaries from: $PGBIN"

# ---------------------------------------------------------------------------
# PostgreSQL servers refuse to run as root. If we are root, perform all
# cluster-management operations as the 'postgres' OS user; otherwise run as the
# current user. Client (psql) connections use trust auth over the local socket,
# so they work regardless of OS user.
# ---------------------------------------------------------------------------
PG_OSUSER=""
if [[ "$(id -u)" -eq 0 ]]; then
  if id postgres >/dev/null 2>&1; then
    PG_OSUSER="postgres"
  else
    echo "ERROR: running as root but no 'postgres' user exists to run the server." >&2
    exit 1
  fi
fi

# Run a command either directly or as the postgres user when we are root.
as_pg() {
  if [[ -n "$PG_OSUSER" ]]; then
    su "$PG_OSUSER" -c "$*"
  else
    bash -c "$*"
  fi
}

PGUSER_ROLE="${PGUSER:-${PG_OSUSER:-$(id -un)}}"

# ---------------------------------------------------------------------------
# Prepare directories.
# ---------------------------------------------------------------------------
mkdir -p "$INV_SOCKET_DIR"
chmod 1777 "$INV_SOCKET_DIR" 2>/dev/null || true

PGDATA_PARENT="$(dirname "$INV_PGDATA")"
mkdir -p "$PGDATA_PARENT"

# ---------------------------------------------------------------------------
# Stop any server already running against this data directory, then recreate
# the data directory from scratch (clean state).
# ---------------------------------------------------------------------------
if [[ -f "$INV_PGDATA/postmaster.pid" ]]; then
  echo "Stopping existing server at $INV_PGDATA ..."
  as_pg "$PGBIN/pg_ctl -D '$INV_PGDATA' -m immediate -w stop" >/dev/null 2>&1 || true
fi

echo "Recreating clean data directory at $INV_PGDATA ..."
rm -rf "$INV_PGDATA"
mkdir -p "$INV_PGDATA"
if [[ -n "$PG_OSUSER" ]]; then
  chown "$PG_OSUSER":"$PG_OSUSER" "$INV_PGDATA" "$PGDATA_PARENT" 2>/dev/null || true
  chown "$PG_OSUSER":"$PG_OSUSER" "$INV_SOCKET_DIR" 2>/dev/null || true
fi

echo "Initializing cluster (initdb) ..."
as_pg "$PGBIN/initdb -D '$INV_PGDATA' --auth-local=trust --auth-host=trust -E UTF8 --locale=C" >/dev/null

# ---------------------------------------------------------------------------
# Start the server on a private port + socket directory.
# ---------------------------------------------------------------------------
echo "Starting server on port $INV_PGPORT (socket: $INV_SOCKET_DIR) ..."
as_pg "$PGBIN/pg_ctl -D '$INV_PGDATA' \
  -o \"-p $INV_PGPORT -k '$INV_SOCKET_DIR' -c listen_addresses=''\" \
  -w -t 60 start" >/dev/null

# Connection settings used by psql and the workload scripts from here on.
export PGHOST="$INV_SOCKET_DIR"
export PGPORT="$INV_PGPORT"
export PGUSER="$PGUSER_ROLE"
export DB_NAME="$DB_NAME"
unset PGDATABASE DATABASE_URL 2>/dev/null || true

# Stop the server on exit unless asked to keep it running.
cleanup() {
  if [[ "$KEEP_RUNNING" != "1" ]]; then
    as_pg "$PGBIN/pg_ctl -D '$INV_PGDATA' -m fast -w stop" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Create the database and load the completed implementation.
# ---------------------------------------------------------------------------
echo "Creating database '$DB_NAME' ..."
"$PGBIN/createdb" -p "$INV_PGPORT" -h "$INV_SOCKET_DIR" -U "$PGUSER_ROLE" "$DB_NAME" 2>/dev/null \
  || psql -p "$INV_PGPORT" -h "$INV_SOCKET_DIR" -U "$PGUSER_ROLE" -d postgres -X -v ON_ERROR_STOP=1 \
       -c "CREATE DATABASE $DB_NAME"

echo "Loading schema, seed, and concurrency-safe implementation ..."
( cd "$SCRIPT_DIR" && psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -f bootstrap.sql >/dev/null )

echo
echo "Inventory reservation system is initialized and running."
echo "  Connect with: psql -h '$INV_SOCKET_DIR' -p $INV_PGPORT -U $PGUSER_ROLE -d $DB_NAME"
echo

# ---------------------------------------------------------------------------
# Validate with the supplied concurrency workloads.
# ---------------------------------------------------------------------------
if [[ "$RUN_WORKLOADS" == "1" ]]; then
  echo "Running supplied concurrency workloads ..."
  echo "======================================================================"
  ( cd "$SCRIPT_DIR" && bash workloads/run_all.sh )
  echo "======================================================================"
fi

echo "Done."
