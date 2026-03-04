-- =============================================================================
-- 04_functions.sql
-- Helper functions consumed by RLS policies and application code.
--
-- Session context is injected by the application at the start of every
-- request inside a transaction:
--
--   BEGIN;
--   SELECT set_rls_context('<user-uuid>', 'customer', '<branch-uuid>');
--   -- ... application queries ...
--   COMMIT;  -- or ROLLBACK
--
-- SET LOCAL ensures the context is automatically cleared at transaction end,
-- preventing context bleed between requests.
-- =============================================================================

\echo '>>> [04] Creating helper functions...'

-- ---------------------------------------------------------------------------
-- set_rls_context
-- Call this at the top of every application transaction.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_rls_context(
    p_user_id   UUID,
    p_role      TEXT,           -- 'customer' | 'staff' | 'admin'
    p_branch_id UUID DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER          -- runs as the function owner (superuser context)
SET search_path = public
AS $$
BEGIN
    IF p_role NOT IN ('customer', 'staff', 'admin') THEN
        RAISE EXCEPTION 'Invalid role: %. Must be customer, staff, or admin.', p_role;
    END IF;

    -- SET LOCAL: variables are scoped to the current transaction
    PERFORM set_config('app.current_user_id',   p_user_id::TEXT,    TRUE);
    PERFORM set_config('app.current_user_role',  p_role,             TRUE);
    PERFORM set_config('app.current_branch_id',
                       COALESCE(p_branch_id::TEXT, ''), TRUE);
END;
$$;

COMMENT ON FUNCTION set_rls_context IS
    'Inject per-request user context consumed by RLS policies. '
    'Must be called inside a transaction (SET LOCAL scope).';

-- ---------------------------------------------------------------------------
-- current_app_user_id()   – returns the UUID set by set_rls_context
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_app_user_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID;
$$;

-- ---------------------------------------------------------------------------
-- current_app_user_role()  – returns 'customer' | 'staff' | 'admin' | NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_app_user_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT NULLIF(current_setting('app.current_user_role', TRUE), '');
$$;

-- ---------------------------------------------------------------------------
-- current_app_branch_id()  – returns the branch UUID or NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_app_branch_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT NULLIF(current_setting('app.current_branch_id', TRUE), '')::UUID;
$$;

-- ---------------------------------------------------------------------------
-- is_admin()  – convenience shorthand used within policies
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT current_app_user_role() = 'admin';
$$;

-- ---------------------------------------------------------------------------
-- is_staff_or_admin()
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_staff_or_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT current_app_user_role() IN ('staff', 'admin');
$$;

-- ---------------------------------------------------------------------------
-- record_audit_event  – called by audit trigger functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_audit_event(
    p_action     TEXT,
    p_table_name TEXT,
    p_record_id  UUID,
    p_old_values JSONB DEFAULT NULL,
    p_new_values JSONB DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO audit_log (user_id, action, table_name, record_id, old_values, new_values)
    VALUES (
        current_app_user_id(),
        p_action,
        p_table_name,
        p_record_id,
        p_old_values,
        p_new_values
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Audit trigger function – attach to any table for automatic change logging
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_action TEXT;
    v_old    JSONB := NULL;
    v_new    JSONB := NULL;
    v_id     UUID;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_action := TG_TABLE_NAME || '.create';
        v_new    := to_jsonb(NEW);
        v_id     := NEW.id;
    ELSIF TG_OP = 'UPDATE' THEN
        v_action := TG_TABLE_NAME || '.update';
        v_old    := to_jsonb(OLD);
        v_new    := to_jsonb(NEW);
        v_id     := NEW.id;
    ELSIF TG_OP = 'DELETE' THEN
        v_action := TG_TABLE_NAME || '.delete';
        v_old    := to_jsonb(OLD);
        v_id     := OLD.id;
    END IF;

    PERFORM record_audit_event(v_action, TG_TABLE_NAME, v_id, v_old, v_new);

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Attach audit triggers to business-critical tables
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['appointments', 'orders', 'order_items', 'users'] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger
            WHERE tgname = 'audit_' || t
              AND tgrelid = t::regclass
        ) THEN
            EXECUTE format(
                'CREATE TRIGGER audit_%I
                 AFTER INSERT OR UPDATE OR DELETE ON %I
                 FOR EACH ROW EXECUTE FUNCTION audit_trigger_func()',
                t, t
            );
        END IF;
    END LOOP;
END;
$$;

\echo '>>> [04] Helper functions created.'
