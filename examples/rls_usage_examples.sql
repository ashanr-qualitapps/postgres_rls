-- =============================================================================
-- rls_usage_examples.sql
-- Copy-paste snippets showing how to use RLS in the beauty_app.
--
-- Run these manually in psql or a SQL client against the beauty_app database.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Connecting as the application service user
-- ─────────────────────────────────────────────────────────────────────────────
-- psql "postgresql://app_service_user:App_S3rvice_P%40ss%21@localhost:5432/beauty_app"


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. CUSTOMER SESSION  (Alice can only see her own data)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;

-- Activate the customer role and inject Alice's identity
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context(
    '22222222-0000-0000-0000-000000000004',   -- Alice's user_id
    'customer',
    '11111111-0000-0000-0000-000000000001'    -- Downtown branch
);

-- Alice sees only her own user record
SELECT id, full_name, email, role FROM users;

-- Alice sees only her own appointments
SELECT id, scheduled_at, status FROM appointments;

-- Alice sees only her own orders
SELECT id, total_amount, status FROM orders;

-- Alice CANNOT see Charlie's appointment (returns 0 rows)
SELECT * FROM appointments
WHERE user_id = '22222222-0000-0000-0000-000000000005';

-- Alice CAN read all active services (browse the menu)
SELECT id, name, price, duration_min FROM services;

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. STAFF SESSION  (Jane at Downtown can see all Downtown data)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;

SET LOCAL ROLE app_staff_role;
SELECT set_rls_context(
    '22222222-0000-0000-0000-000000000002',   -- Jane's user_id
    'staff',
    '11111111-0000-0000-0000-000000000001'    -- Downtown branch
);

-- Jane sees all users in Downtown (Alice — NOT Charlie who is Uptown)
SELECT id, full_name, email, role FROM users;

-- Jane sees all Downtown appointments
SELECT id, user_id, scheduled_at, status FROM appointments;

-- Jane CANNOT see Uptown appointments
SELECT * FROM appointments
WHERE branch_id = '11111111-0000-0000-0000-000000000002';

-- Jane can update an appointment status
UPDATE appointments
   SET status = 'confirmed'
 WHERE id = '44444444-0000-0000-0000-000000000001';

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ADMIN SESSION  (full access across all branches)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;

SET LOCAL ROLE app_admin_role;
SELECT set_rls_context(
    '22222222-0000-0000-0000-000000000001',   -- Admin user_id
    'admin'
    -- branch_id is optional / irrelevant for admins
);

-- Admin sees ALL users
SELECT id, full_name, email, role, branch_id FROM users;

-- Admin sees ALL appointments across all branches
SELECT id, user_id, branch_id, scheduled_at, status FROM appointments;

-- Admin can insert a new branch
INSERT INTO branches (name, address, phone, timezone)
VALUES ('Midtown Spa', '300 5th Ave', '+1-555-0303', 'America/New_York')
RETURNING id, name;

-- Admin can delete a service
-- DELETE FROM services WHERE id = '33333333-0000-0000-0000-000000000005';

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Security test: context NOT set → all private tables return 0 rows
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN;

SET LOCAL ROLE app_customer_role;
-- No set_rls_context() call

-- Should return 0 rows because current_app_user_id() is NULL
SELECT count(*) AS should_be_zero FROM users;
SELECT count(*) AS should_be_zero FROM appointments;

COMMIT;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Inspect all RLS policies
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    c.relname        AS table_name,
    p.polname        AS policy_name,
    p.polcmd         AS command,   -- r=SELECT, w=INSERT, a=UPDATE, d=DELETE, *=ALL
    p.polpermissive  AS is_permissive,
    r.rolname        AS role,
    pg_get_expr(p.polqual,    p.polrelid) AS using_expr,
    pg_get_expr(p.polwithcheck, p.polrelid) AS with_check_expr
FROM pg_policy p
JOIN pg_class  c ON c.oid = p.polrelid
JOIN pg_roles  r ON r.oid = ANY(p.polroles)
ORDER BY c.relname, p.polname;
