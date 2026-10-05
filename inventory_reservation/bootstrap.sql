-- Loads the schema, deterministic seed data, and the concurrency-safe
-- implementation. This is the canonical bootstrap for the completed solution
-- (the supplied bootstrap_starter.sql still loads the original, sequential-only
-- starter implementation for comparison).
\set ON_ERROR_STOP on
\ir 00_schema.sql
\ir 01_seed.sql
\ir 02_implementation.sql
