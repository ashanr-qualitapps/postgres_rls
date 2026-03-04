-- =============================================================================
-- 02_extensions.sql
-- Enable PostgreSQL extensions required by beauty_app.
-- =============================================================================

\echo '>>> [02] Enabling extensions...'

-- UUID generation (pgcrypto or uuid-ossp)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Cryptographic functions (used for password hashing in demo seed data)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Additional type checks / citext for case-insensitive email columns
CREATE EXTENSION IF NOT EXISTS citext;

\echo '>>> [02] Extensions enabled.'
