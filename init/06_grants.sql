-- =============================================================================
-- 06_grants.sql
-- Grant privileges to all application roles.
-- Object-level privileges let roles reach the rows; RLS decides which rows.
-- =============================================================================

\echo '>>> [06] Granting privileges...'

-- ---------------------------------------------------------------------------
-- Schema usage
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO
    app_readonly,
    app_customer_role,
    app_staff_role,
    app_admin_role;

-- ---------------------------------------------------------------------------
-- Sequences  (needed for BIGSERIAL columns like audit_log.id)
-- ---------------------------------------------------------------------------
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO
    app_customer_role,
    app_staff_role,
    app_admin_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO
        app_customer_role,
        app_staff_role,
        app_admin_role;

-- ---------------------------------------------------------------------------
-- app_readonly – read-only across all tables
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO app_readonly;

-- ---------------------------------------------------------------------------
-- app_customer_role
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON
    users,
    branches,
    services,
    appointments,
    products,
    orders,
    order_items,
    audit_log
TO app_customer_role;

-- ---------------------------------------------------------------------------
-- app_staff_role
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON
    users,
    branches,
    services,
    appointments,
    products,
    orders,
    order_items,
    audit_log
TO app_staff_role;

-- ---------------------------------------------------------------------------
-- app_admin_role  – full DML; no DDL (DDL belongs to the owner)
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON
    users,
    branches,
    services,
    appointments,
    products,
    orders,
    order_items,
    audit_log
TO app_admin_role;

-- ---------------------------------------------------------------------------
-- Grant EXECUTE on application functions to all roles
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION set_rls_context(UUID, TEXT, UUID)   TO app_customer_role, app_staff_role, app_admin_role;
GRANT EXECUTE ON FUNCTION current_app_user_id()               TO app_customer_role, app_staff_role, app_admin_role;
GRANT EXECUTE ON FUNCTION current_app_user_role()             TO app_customer_role, app_staff_role, app_admin_role;
GRANT EXECUTE ON FUNCTION current_app_branch_id()             TO app_customer_role, app_staff_role, app_admin_role;
GRANT EXECUTE ON FUNCTION is_admin()                          TO app_customer_role, app_staff_role, app_admin_role;
GRANT EXECUTE ON FUNCTION is_staff_or_admin()                 TO app_customer_role, app_staff_role, app_admin_role;

\echo '>>> [06] Privileges granted.'
