-- =============================================================================
-- 01_roles.sql
-- Create all database roles used by the beauty_app.
--
-- Role hierarchy:
--   app_readonly       – SELECT only on public schema (reporting)
--   app_customer_role  – nologin, maps to a customer session
--   app_staff_role     – nologin, maps to a staff session
--   app_admin_role     – nologin, maps to an admin session
--   app_service_user   – login role used by the application server
-- =============================================================================

\echo '>>> [01] Creating roles...'

-- ---------------------------------------------------------------------------
-- Non-login group roles (privilege containers)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_readonly') THEN
        CREATE ROLE app_readonly NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;

    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_customer_role') THEN
        CREATE ROLE app_customer_role NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;

    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_staff_role') THEN
        CREATE ROLE app_staff_role NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;

    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_admin_role') THEN
        CREATE ROLE app_admin_role NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;

    -- The single login role the application server uses.
    -- Its effective privileges are set per-request via SET LOCAL role.
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_service_user') THEN
        CREATE ROLE app_service_user
            LOGIN
            NOSUPERUSER NOCREATEDB NOCREATEROLE
            PASSWORD 'App_S3rvice_P@ss!';
    END IF;
END;
$$;

-- Grant group memberships so app_service_user can SET ROLE to each
GRANT app_readonly      TO app_service_user;
GRANT app_customer_role TO app_service_user;
GRANT app_staff_role    TO app_service_user;
GRANT app_admin_role    TO app_service_user;

\echo '>>> [01] Roles created.'
