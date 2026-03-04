-- =============================================================================
-- 05_rls.sql
-- Row Level Security policies for beauty_app.
--
-- Design principles
-- ─────────────────
-- • All data tables have RLS ENABLED + FORCED so even the table owner
--   (beauty_admin) is subject to policies when connecting as app_service_user.
-- • Three tiers:
--     customer  → sees only their own rows (user_id = current_app_user_id())
--     staff     → sees all rows belonging to their branch
--     admin     → unrestricted (USING (TRUE))
-- • The application MUST call set_rls_context() inside each transaction.
--   Without it, current_app_user_id() returns NULL and all data is hidden.
-- =============================================================================

\echo '>>> [05] Enabling Row Level Security...'

-- ---------------------------------------------------------------------------
-- Helper: drop a policy if it already exists (idempotent re-runs)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _drop_policy_if_exists(p_policy TEXT, p_table TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        WHERE p.polname = p_policy
          AND c.relname = p_table
    ) THEN
        EXECUTE format('DROP POLICY %I ON %I', p_policy, p_table);
    END IF;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: users
-- ─ Customers see only themselves.
-- ─ Staff see all users in their branch.
-- ─ Admins see everything.
-- ─ Nobody can read password_hash via these policies (column-level security
--   should be added in production via a VIEW or SECURITY BARRIER VIEW).
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;

SELECT _drop_policy_if_exists('users_select_customer', 'users');
CREATE POLICY users_select_customer ON users
    AS PERMISSIVE FOR SELECT
    TO app_customer_role
    USING (id = current_app_user_id());

SELECT _drop_policy_if_exists('users_select_staff', 'users');
CREATE POLICY users_select_staff ON users
    AS PERMISSIVE FOR SELECT
    TO app_staff_role
    USING (
        is_staff_or_admin()
        AND branch_id = current_app_branch_id()
    );

SELECT _drop_policy_if_exists('users_select_admin', 'users');
CREATE POLICY users_select_admin ON users
    AS PERMISSIVE FOR SELECT
    TO app_admin_role
    USING (is_admin());

-- Customers can update only their own profile (not role, not branch_id)
SELECT _drop_policy_if_exists('users_update_customer', 'users');
CREATE POLICY users_update_customer ON users
    AS PERMISSIVE FOR UPDATE
    TO app_customer_role
    USING  (id = current_app_user_id())
    WITH CHECK (id = current_app_user_id());

-- Staff can update users in their branch
SELECT _drop_policy_if_exists('users_update_staff', 'users');
CREATE POLICY users_update_staff ON users
    AS PERMISSIVE FOR UPDATE
    TO app_staff_role
    USING  (is_staff_or_admin() AND branch_id = current_app_branch_id())
    WITH CHECK (is_staff_or_admin() AND branch_id = current_app_branch_id());

-- Admins can do anything on users
SELECT _drop_policy_if_exists('users_all_admin', 'users');
CREATE POLICY users_all_admin ON users
    AS PERMISSIVE FOR ALL
    TO app_admin_role
    USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: branches
-- ─ Readable by all authenticated sessions.
-- ─ Only admins can modify.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE branches FORCE ROW LEVEL SECURITY;

SELECT _drop_policy_if_exists('branches_select_all', 'branches');
CREATE POLICY branches_select_all ON branches
    AS PERMISSIVE FOR SELECT
    TO app_customer_role, app_staff_role, app_admin_role
    USING (TRUE);

SELECT _drop_policy_if_exists('branches_modify_admin', 'branches');
CREATE POLICY branches_modify_admin ON branches
    AS PERMISSIVE FOR ALL
    TO app_admin_role
    USING  (is_admin())
    WITH CHECK (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: services
-- ─ All authenticated users can read active services.
-- ─ Staff can read all services for their branch.
-- ─ Only admins can INSERT / UPDATE / DELETE services.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE services ENABLE ROW LEVEL SECURITY;
ALTER TABLE services FORCE ROW LEVEL SECURITY;

SELECT _drop_policy_if_exists('services_select_customer', 'services');
CREATE POLICY services_select_customer ON services
    AS PERMISSIVE FOR SELECT
    TO app_customer_role
    USING (is_active = TRUE);

SELECT _drop_policy_if_exists('services_select_staff', 'services');
CREATE POLICY services_select_staff ON services
    AS PERMISSIVE FOR SELECT
    TO app_staff_role
    USING (
        is_staff_or_admin()
        AND (branch_id = current_app_branch_id() OR branch_id IS NULL)
    );

SELECT _drop_policy_if_exists('services_all_admin', 'services');
CREATE POLICY services_all_admin ON services
    AS PERMISSIVE FOR ALL
    TO app_admin_role
    USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: appointments
-- ─ Customers see only their own appointments.
-- ─ Staff see all appointments for their branch.
-- ─ Admins see everything and can update any field.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments FORCE ROW LEVEL SECURITY;

-- Customer: SELECT
SELECT _drop_policy_if_exists('appointments_select_customer', 'appointments');
CREATE POLICY appointments_select_customer ON appointments
    AS PERMISSIVE FOR SELECT
    TO app_customer_role
    USING (user_id = current_app_user_id());

-- Customer: INSERT (can only book for themselves)
SELECT _drop_policy_if_exists('appointments_insert_customer', 'appointments');
CREATE POLICY appointments_insert_customer ON appointments
    AS PERMISSIVE FOR INSERT
    TO app_customer_role
    WITH CHECK (user_id = current_app_user_id());

-- Customer: UPDATE own pending appointments (cancel or reschedule)
SELECT _drop_policy_if_exists('appointments_update_customer', 'appointments');
CREATE POLICY appointments_update_customer ON appointments
    AS PERMISSIVE FOR UPDATE
    TO app_customer_role
    USING  (user_id = current_app_user_id() AND status IN ('pending','confirmed'))
    WITH CHECK (user_id = current_app_user_id());

-- Staff: SELECT all appointments in their branch
SELECT _drop_policy_if_exists('appointments_select_staff', 'appointments');
CREATE POLICY appointments_select_staff ON appointments
    AS PERMISSIVE FOR SELECT
    TO app_staff_role
    USING (is_staff_or_admin() AND branch_id = current_app_branch_id());

-- Staff: UPDATE appointments in their branch (change status, add notes)
SELECT _drop_policy_if_exists('appointments_update_staff', 'appointments');
CREATE POLICY appointments_update_staff ON appointments
    AS PERMISSIVE FOR UPDATE
    TO app_staff_role
    USING  (is_staff_or_admin() AND branch_id = current_app_branch_id())
    WITH CHECK (is_staff_or_admin() AND branch_id = current_app_branch_id());

-- Admin: ALL
SELECT _drop_policy_if_exists('appointments_all_admin', 'appointments');
CREATE POLICY appointments_all_admin ON appointments
    AS PERMISSIVE FOR ALL
    TO app_admin_role
    USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: products
-- ─ Customers read active products.
-- ─ Staff read all products for their branch.
-- ─ Admins can do everything.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE products FORCE ROW LEVEL SECURITY;

SELECT _drop_policy_if_exists('products_select_customer', 'products');
CREATE POLICY products_select_customer ON products
    AS PERMISSIVE FOR SELECT
    TO app_customer_role
    USING (is_active = TRUE);

SELECT _drop_policy_if_exists('products_select_staff', 'products');
CREATE POLICY products_select_staff ON products
    AS PERMISSIVE FOR SELECT
    TO app_staff_role
    USING (
        is_staff_or_admin()
        AND (branch_id = current_app_branch_id() OR branch_id IS NULL)
    );

SELECT _drop_policy_if_exists('products_all_admin', 'products');
CREATE POLICY products_all_admin ON products
    AS PERMISSIVE FOR ALL
    TO app_admin_role
    USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: orders
-- ─ Customers see only their own orders.
-- ─ Staff see orders placed at their branch.
-- ─ Admins see all.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders FORCE ROW LEVEL SECURITY;

SELECT _drop_policy_if_exists('orders_select_customer', 'orders');
CREATE POLICY orders_select_customer ON orders
    AS PERMISSIVE FOR SELECT
    TO app_customer_role
    USING (user_id = current_app_user_id());

SELECT _drop_policy_if_exists('orders_insert_customer', 'orders');
CREATE POLICY orders_insert_customer ON orders
    AS PERMISSIVE FOR INSERT
    TO app_customer_role
    WITH CHECK (user_id = current_app_user_id());

SELECT _drop_policy_if_exists('orders_select_staff', 'orders');
CREATE POLICY orders_select_staff ON orders
    AS PERMISSIVE FOR SELECT
    TO app_staff_role
    USING (is_staff_or_admin() AND branch_id = current_app_branch_id());

SELECT _drop_policy_if_exists('orders_update_staff', 'orders');
CREATE POLICY orders_update_staff ON orders
    AS PERMISSIVE FOR UPDATE
    TO app_staff_role
    USING  (is_staff_or_admin() AND branch_id = current_app_branch_id())
    WITH CHECK (is_staff_or_admin() AND branch_id = current_app_branch_id());

SELECT _drop_policy_if_exists('orders_all_admin', 'orders');
CREATE POLICY orders_all_admin ON orders
    AS PERMISSIVE FOR ALL
    TO app_admin_role
    USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: order_items
-- ─ Visibility inherits from orders through JOIN; direct policies mirror orders.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items FORCE ROW LEVEL SECURITY;

SELECT _drop_policy_if_exists('order_items_select_customer', 'order_items');
CREATE POLICY order_items_select_customer ON order_items
    AS PERMISSIVE FOR SELECT
    TO app_customer_role
    USING (
        EXISTS (
            SELECT 1 FROM orders o
            WHERE o.id = order_items.order_id
              AND o.user_id = current_app_user_id()
        )
    );

SELECT _drop_policy_if_exists('order_items_insert_customer', 'order_items');
CREATE POLICY order_items_insert_customer ON order_items
    AS PERMISSIVE FOR INSERT
    TO app_customer_role
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM orders o
            WHERE o.id = order_items.order_id
              AND o.user_id = current_app_user_id()
        )
    );

SELECT _drop_policy_if_exists('order_items_select_staff', 'order_items');
CREATE POLICY order_items_select_staff ON order_items
    AS PERMISSIVE FOR SELECT
    TO app_staff_role
    USING (
        is_staff_or_admin()
        AND EXISTS (
            SELECT 1 FROM orders o
            WHERE o.id = order_items.order_id
              AND o.branch_id = current_app_branch_id()
        )
    );

SELECT _drop_policy_if_exists('order_items_all_admin', 'order_items');
CREATE POLICY order_items_all_admin ON order_items
    AS PERMISSIVE FOR ALL
    TO app_admin_role
    USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLE: audit_log
-- ─ Customers can see only their own audit entries.
-- ─ Staff can see audit entries for their branch users.
-- ─ Admins see everything; only via app (INSERT, no UPDATE/DELETE for anyone).
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;

SELECT _drop_policy_if_exists('audit_log_select_customer', 'audit_log');
CREATE POLICY audit_log_select_customer ON audit_log
    AS PERMISSIVE FOR SELECT
    TO app_customer_role
    USING (user_id = current_app_user_id());

-- INSERT is allowed so the app can write audit events
SELECT _drop_policy_if_exists('audit_log_insert_all', 'audit_log');
CREATE POLICY audit_log_insert_all ON audit_log
    AS PERMISSIVE FOR INSERT
    TO app_customer_role, app_staff_role, app_admin_role
    WITH CHECK (TRUE);

SELECT _drop_policy_if_exists('audit_log_select_admin', 'audit_log');
CREATE POLICY audit_log_select_admin ON audit_log
    AS PERMISSIVE FOR SELECT
    TO app_admin_role
    USING (is_admin());

SELECT _drop_policy_if_exists('audit_log_select_staff', 'audit_log');
CREATE POLICY audit_log_select_staff ON audit_log
    AS PERMISSIVE FOR SELECT
    TO app_staff_role
    USING (
        is_staff_or_admin()
        AND EXISTS (
            SELECT 1 FROM users u
            WHERE u.id = audit_log.user_id
              AND u.branch_id = current_app_branch_id()
        )
    );

-- Clean up helper
DROP FUNCTION _drop_policy_if_exists(TEXT, TEXT);

\echo '>>> [05] Row Level Security policies applied.'
