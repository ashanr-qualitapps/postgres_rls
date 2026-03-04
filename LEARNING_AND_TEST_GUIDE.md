# Learning Plan & Test Guide — beauty_app PostgreSQL

A structured path to understanding every layer of this PostgreSQL service, followed by a comprehensive test guide you can run locally.

---

## Table of Contents

1. [Learning Plan](#learning-plan)
   - [Module 1 — Infrastructure & Environment](#module-1--infrastructure--environment)
   - [Module 2 — Schema & Data Model](#module-2--schema--data-model)
   - [Module 3 — Roles & Permissions](#module-3--roles--permissions)
   - [Module 4 — Session Context & Helper Functions](#module-4--session-context--helper-functions)
   - [Module 5 — Row Level Security (RLS)](#module-5--row-level-security-rls)
   - [Module 6 — Audit Logging](#module-6--audit-logging)
   - [Module 7 — Scalability & Production Readiness](#module-7--scalability--production-readiness)
2. [Test Guide](#test-guide)
   - [Prerequisites](#prerequisites)
   - [T1 — Environment Health](#t1--environment-health)
   - [T2 — Schema Verification](#t2--schema-verification)
   - [T3 — Roles & Grants](#t3--roles--grants)
   - [T4 — RLS: Customer Isolation](#t4--rls-customer-isolation)
   - [T5 — RLS: Staff Branch Scope](#t5--rls-staff-branch-scope)
   - [T6 — RLS: Admin Full Access](#t6--rls-admin-full-access)
   - [T7 — RLS: No Context = No Data](#t7--rls-no-context--no-data)
   - [T8 — Appointments Workflow](#t8--appointments-workflow)
   - [T9 — Orders & Order Items](#t9--orders--order-items)
   - [T10 — Audit Log](#t10--audit-log)
   - [T11 — Negative / Security Tests](#t11--negative--security-tests)
   - [T12 — pgAdmin Smoke Test](#t12--pgadmin-smoke-test)

---

## Learning Plan

Work through each module in order. Each module lists the **files to read**, **key concepts**, and **hands-on exercises**.

---

### Module 1 — Infrastructure & Environment

**Estimated time:** 30 minutes

**Files to read:**
| File | What to focus on |
|---|---|
| [Dockerfile](Dockerfile) | Base image, contrib extensions, custom config mount |
| [docker-compose.yml](docker-compose.yml) | Service dependencies, volume mounts, health check |
| [config/postgresql.conf](config/postgresql.conf) | Connection limits, memory, WAL settings |
| [README.md](README.md) | Full quick-start and project structure |

**Key concepts:**
- PostgreSQL init script execution order (`/docker-entrypoint-initdb.d/`)
- Why `postgres:16-alpine` is used over full Debian image
- How `postgresql.conf` is injected via bind mount rather than baked into the image
- Health check pattern: `pg_isready` gates pgAdmin startup
- The single `beauty_net` Docker network isolating all services

**Hands-on exercises:**
```bash
# 1. Start the stack
docker compose up -d

# 2. Verify containers are healthy
docker compose ps

# 3. Check PostgreSQL logs for init script execution
docker logs beauty_app_postgres 2>&1 | grep ">>>"

# 4. Connect as the superuser
docker exec -it beauty_app_postgres psql -U beauty_admin -d beauty_app

# 5. Re-run init from scratch (destructive — for learning only)
docker compose down -v && docker compose up -d
```

---

### Module 2 — Schema & Data Model

**Estimated time:** 45 minutes

**Files to read:**
| File | What to focus on |
|---|---|
| [init/03_schema.sql](init/03_schema.sql) | All 8 tables, indexes, check constraints, foreign keys |
| [init/07_seed.sql](init/07_seed.sql) | Sample data layout and UUID references |

**Key concepts:**

```
branches
  ├── users         (branch_id FK, role: customer/staff/admin)
  ├── services      (branch_id FK)
  ├── appointments  (user_id + staff_id + service_id + branch_id)
  ├── products      (branch_id FK)
  └── orders        (user_id + branch_id)
         └── order_items  (order_id + product_id)

audit_log           (append-only, records changes to appointments/orders/users)
```

- Every user-owned table carries a `user_id UUID` column — this is the RLS anchor
- `CITEXT` type on `users.email` provides case-insensitive uniqueness for free
- `updated_at` is maintained automatically via the `trigger_set_updated_at()` trigger
- `pgcrypto` is used to hash passwords in seed data (`crypt(...)`)
- `CHECK` constraints enforce valid status values and non-negative prices/quantities

**Hands-on exercises:**
```sql
-- Connect first:
-- docker exec -it beauty_app_postgres psql -U beauty_admin -d beauty_app

-- List all tables
\dt

-- Inspect appointments table structure
\d appointments

-- View seed data
SELECT id, full_name, role, branch_id FROM users;
SELECT id, name, status, scheduled_at FROM appointments;

-- Check a trigger is attached
SELECT trigger_name, event_manipulation, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'public'
ORDER BY event_object_table;
```

---

### Module 3 — Roles & Permissions

**Estimated time:** 30 minutes

**Files to read:**
| File | What to focus on |
|---|---|
| [init/01_roles.sql](init/01_roles.sql) | Role hierarchy and `GRANT ... TO app_service_user` |
| [init/06_grants.sql](init/06_grants.sql) | Object-level `GRANT` statements per role |

**Key concepts:**

```
app_service_user  (single LOGIN role used by the app server)
  ├── app_readonly       (SELECT only, for reporting)
  ├── app_customer_role  (nologin group role)
  ├── app_staff_role     (nologin group role)
  └── app_admin_role     (nologin group role)
```

- `app_service_user` connects to the database — it never queries directly under its own identity
- At the start of each request the app calls `SET LOCAL ROLE app_customer_role` (or staff/admin) to activate the correct privilege tier
- Object-level grants (from `06_grants.sql`) determine *which tables/sequences* a role can touch
- RLS policies (from `05_rls.sql`) determine *which rows* within those tables are visible

**Hands-on exercises:**
```sql
-- List all application roles
SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname LIKE 'app%';

-- See role membership tree
SELECT r.rolname AS role, m.rolname AS member_of
FROM pg_auth_members am
JOIN pg_roles r  ON r.oid  = am.roleid
JOIN pg_roles m  ON m.oid  = am.member
WHERE r.rolname LIKE 'app%';

-- Check grants on the appointments table
\dp appointments
```

---

### Module 4 — Session Context & Helper Functions

**Estimated time:** 40 minutes

**Files to read:**
| File | What to focus on |
|---|---|
| [init/04_functions.sql](init/04_functions.sql) | `set_rls_context`, `current_app_user_id`, `is_admin`, audit trigger |

**Key concepts:**
- `set_rls_context(user_uuid, role, branch_uuid)` uses `SET LOCAL` which scopes variables to the **current transaction** — they are cleared automatically on `COMMIT`/`ROLLBACK`
- `current_setting('app.current_user_id', TRUE)` reads the per-transaction variable; the `TRUE` flag prevents an error if the variable is not set (returns `''` instead)
- `SECURITY DEFINER` on `set_rls_context` and `record_audit_event` lets them run with elevated privileges regardless of the calling role
- `STABLE` on the `current_app_*` helpers tells the query planner these functions return the same value within a single query — important for RLS plan caching

**The request lifecycle:**
```
App Server
  │
  ├─ BEGIN
  ├─ SET LOCAL ROLE app_customer_role
  ├─ SELECT set_rls_context('<uuid>', 'customer', '<branch_uuid>')
  ├─ ... application queries (RLS auto-filters rows) ...
  └─ COMMIT  ← context variables are automatically cleared
```

**Hands-on exercises:**
```sql
-- Test context injection
BEGIN;
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context(
    (SELECT id FROM users WHERE role = 'customer' LIMIT 1),
    'customer',
    (SELECT branch_id FROM users WHERE role = 'customer' LIMIT 1)
);
SELECT current_app_user_id(), current_app_user_role(), current_app_branch_id();
COMMIT;

-- Verify context is cleared after commit
SELECT current_app_user_id();   -- should return NULL
```

---

### Module 5 — Row Level Security (RLS)

**Estimated time:** 60 minutes

**Files to read:**
| File | What to focus on |
|---|---|
| [init/05_rls.sql](init/05_rls.sql) | All policies across all 8 tables |
| [examples/rls_usage_examples.sql](examples/rls_usage_examples.sql) | Ready-to-run queries per role |

**Key concepts:**

| Role | `users` | `branches` | `services` | `appointments` | `products` | `orders` |
|---|---|---|---|---|---|---|
| customer | Own row only | SELECT all | Active only | Own rows only | Active only | Own rows only |
| staff | Branch users | SELECT all | Branch only | Branch only | Branch only | Branch only |
| admin | All rows | Full CRUD | Full CRUD | Full CRUD | Full CRUD | Full CRUD |

- `FORCE ROW LEVEL SECURITY` applies policies even to the table owner (`beauty_admin`)
- Policies are **additive per role tier**: a PERMISSIVE policy on `app_customer_role` does not affect `app_staff_role`
- `_drop_policy_if_exists()` makes the script **idempotent** — safe to re-run without errors
- `order_items` visibility is derived: customers see items belonging to their own orders via a correlated `EXISTS` subquery

**Hands-on exercises:**

See the full test scenarios in the [Test Guide](#test-guide) below.

---

### Module 6 — Audit Logging

**Estimated time:** 20 minutes

**Files to read:**
| File | What to focus on |
|---|---|
| [init/04_functions.sql](init/04_functions.sql) lines 115–180 | `audit_trigger_func`, `record_audit_event` |
| [init/03_schema.sql](init/03_schema.sql) | `audit_log` table definition |
| [init/05_rls.sql](init/05_rls.sql) | RLS policies on `audit_log` |

**Key concepts:**
- The audit trigger fires on `INSERT`, `UPDATE`, and `DELETE` on `appointments`, `orders`, `order_items`, and `users`
- Old and new row values are stored as `JSONB` — enables full before/after diffs
- `current_app_user_id()` in the trigger captures *who* made the change (not the DB role)
- The `audit_log` table is **write-only for non-admins** via RLS — customers and staff cannot read or delete audit entries

---

### Module 7 — Scalability & Production Readiness

**Estimated time:** 30 minutes

**Files to read:**
| File | What to focus on |
|---|---|
| [SCALABILITY.md](SCALABILITY.md) | Connection pooling, replication, partitioning, monitoring |

**Key concepts:**
- Each PostgreSQL connection costs ~5–10 MB RAM — pooling is essential beyond 500 DAU
- PgBouncer in **transaction mode** is the recommended pooler (session-mode is incompatible with `SET LOCAL`)
- Read replicas offload analytical/reporting queries; the `app_readonly` role was designed for this
- The `branch_id` column on most tables doubles as the natural partition key for future table partitioning
- RLS performance: policies use indexed columns (`user_id`, `branch_id`) — check with `EXPLAIN ANALYZE`

---

## Test Guide

All tests connect as `app_service_user` (the application role) and use `SET LOCAL ROLE` + `set_rls_context()` to simulate different user types.

### Prerequisites

```bash
# Start the stack
docker compose up -d

# Open a psql session
docker exec -it beauty_app_postgres psql -U beauty_admin -d beauty_app

# Or connect as app_service_user (closer to real app behavior)
docker exec -it beauty_app_postgres \
  psql "postgresql://app_service_user:App_S3rvice_P@ss!@localhost/beauty_app"
```

Capture seed UUIDs for use in tests:
```sql
-- Run these once and note the output
SELECT id AS branch1_id  FROM branches ORDER BY created_at LIMIT 1;
SELECT id AS branch2_id  FROM branches ORDER BY created_at OFFSET 1 LIMIT 1;
SELECT id AS customer1_id, branch_id FROM users WHERE role = 'customer' ORDER BY created_at LIMIT 1;
SELECT id AS customer2_id, branch_id FROM users WHERE role = 'customer' ORDER BY created_at OFFSET 1 LIMIT 1;
SELECT id AS staff1_id,    branch_id FROM users WHERE role = 'staff'    ORDER BY created_at LIMIT 1;
SELECT id AS admin_id               FROM users WHERE role = 'admin'     LIMIT 1;
```

---

### T1 — Environment Health

**Goal:** Confirm containers are running and init scripts executed successfully.

```bash
# All containers show "healthy"
docker compose ps

# Init steps all logged
docker logs beauty_app_postgres 2>&1 | grep ">>>"
# Expected output:
# >>> [01] Creating roles...
# >>> [01] Roles created.
# >>> [02] Enabling extensions...
# ...through [07]
```

```sql
-- Confirm extensions
SELECT extname FROM pg_extension WHERE extname IN ('uuid-ossp','pgcrypto','citext');
-- Expected: 3 rows

-- Confirm tables exist
SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;
-- Expected: appointments, audit_log, branches, order_items, orders, products, services, users
```

**Pass criteria:** 8 tables present, 3 extensions enabled, all containers healthy.

---

### T2 — Schema Verification

**Goal:** Verify table structure, constraints, indexes, and triggers.

```sql
-- Confirm RLS is enabled on all business tables
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN ('users','branches','services','appointments','products','orders','order_items','audit_log')
  AND relkind = 'r'
ORDER BY relname;
-- Expected: relrowsecurity = true, relforcerowsecurity = true for all rows

-- Confirm updated_at triggers
SELECT trigger_name, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND trigger_name LIKE 'set_%_updated_at'
ORDER BY event_object_table;
-- Expected: one trigger per non-audit table (branches, users, services, appointments, products, orders)

-- Confirm audit triggers
SELECT trigger_name, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND trigger_name LIKE 'audit_%'
ORDER BY event_object_table;
-- Expected: triggers on appointments, orders, order_items, users

-- Confirm seed data loaded
SELECT COUNT(*) FROM branches;       -- >= 2
SELECT COUNT(*) FROM users;          -- >= 3 (1 customer, 1 staff, 1 admin)
SELECT COUNT(*) FROM services;       -- >= 1
SELECT COUNT(*) FROM appointments;   -- >= 1
```

**Pass criteria:** All RLS flags set, all triggers present, seed counts non-zero.

---

### T3 — Roles & Grants

**Goal:** Confirm role hierarchy and object-level privileges.

```sql
-- All app roles exist
SELECT rolname FROM pg_roles WHERE rolname LIKE 'app%' ORDER BY rolname;
-- Expected: app_admin_role, app_customer_role, app_readonly, app_service_user, app_staff_role

-- app_service_user can become any role
SELECT r.rolname
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE m.rolname = 'app_service_user'
ORDER BY r.rolname;
-- Expected: app_admin_role, app_customer_role, app_readonly, app_staff_role

-- Inspect grants on appointments (check INSERT/UPDATE/SELECT per role)
\dp appointments
```

**Pass criteria:** 5 app roles, 4 memberships for `app_service_user`.

---

### T4 — RLS: Customer Isolation

**Goal:** A customer can only see their own rows across all tables.

```sql
-- Replace the UUIDs below with your seed values from the Prerequisites section

BEGIN;
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context(
    '<customer1_id>',
    'customer',
    '<branch1_id>'
);

-- T4.1: Customer sees only their own user record
SELECT id, full_name, role FROM users;
-- Expected: exactly 1 row — their own

-- T4.2: Customer cannot see other customers' appointments
SELECT id, status, scheduled_at FROM appointments;
-- Expected: only rows where user_id = customer1_id

-- T4.3: Customer sees all active services (browsing catalog)
SELECT id, name, is_active FROM services;
-- Expected: only rows where is_active = TRUE

-- T4.4: Customer sees their own orders only
SELECT id, total_amount, status FROM orders;
-- Expected: only rows where user_id = customer1_id

-- T4.5: Customer can book an appointment for themselves
INSERT INTO appointments (user_id, service_id, branch_id, scheduled_at, status)
VALUES (
    '<customer1_id>',
    (SELECT id FROM services WHERE is_active = TRUE LIMIT 1),
    '<branch1_id>',
    NOW() + interval '1 day',
    'pending'
);
-- Expected: INSERT 0 1

-- T4.6: Customer CANNOT book an appointment for another customer
INSERT INTO appointments (user_id, service_id, branch_id, scheduled_at, status)
VALUES (
    '<customer2_id>',    -- different customer!
    (SELECT id FROM services WHERE is_active = TRUE LIMIT 1),
    '<branch1_id>',
    NOW() + interval '2 days',
    'pending'
);
-- Expected: ERROR  (new row violates WITH CHECK on policy)

ROLLBACK;
```

**Pass criteria:** T4.1–T4.5 succeed, T4.6 raises a policy violation error.

---

### T5 — RLS: Staff Branch Scope

**Goal:** A staff member sees all data for their branch but nothing from other branches.

```sql
-- Replace UUIDs with your seed values

BEGIN;
SET LOCAL ROLE app_staff_role;
SELECT set_rls_context(
    '<staff1_id>',
    'staff',
    '<branch1_id>'    -- staff member's assigned branch
);

-- T5.1: Staff sees all users in their branch
SELECT id, full_name, role, branch_id FROM users;
-- Expected: all users where branch_id = branch1_id

-- T5.2: Staff does NOT see users from branch2
SELECT COUNT(*) FROM users WHERE branch_id = '<branch2_id>';
-- Expected: 0

-- T5.3: Staff sees all appointments for their branch
SELECT id, user_id, status, branch_id FROM appointments;
-- Expected: all rows where branch_id = branch1_id

-- T5.4: Staff can update appointment status
UPDATE appointments
SET status = 'confirmed'
WHERE branch_id = '<branch1_id>'
  AND status = 'pending'
RETURNING id, status;
-- Expected: UPDATE n (n >= 1 if pending appointments exist in branch1)

-- T5.5: Staff CANNOT update appointments in another branch
UPDATE appointments
SET status = 'confirmed'
WHERE branch_id = '<branch2_id>';
-- Expected: UPDATE 0  (RLS silently blocks, no error — rows invisible)

ROLLBACK;
```

**Pass criteria:** T5.1–T5.4 behave as expected, T5.5 returns `UPDATE 0`.

---

### T6 — RLS: Admin Full Access

**Goal:** An admin can read and modify everything regardless of branch.

```sql
BEGIN;
SET LOCAL ROLE app_admin_role;
SELECT set_rls_context('<admin_id>', 'admin', NULL);

-- T6.1: Admin sees ALL users across all branches
SELECT COUNT(*) FROM users;
-- Expected: total seed user count (>= 3)

-- T6.2: Admin sees ALL appointments
SELECT COUNT(*) FROM appointments;
-- Expected: total seed appointment count

-- T6.3: Admin can INSERT a new branch
INSERT INTO branches (name, address, timezone)
VALUES ('Test Branch', '1 Test St', 'UTC')
RETURNING id, name;
-- Expected: INSERT 0 1

-- T6.4: Admin can DELETE a record from any branch
-- (use a test record to avoid damaging seed data — rollback covers this)
DELETE FROM branches WHERE name = 'Test Branch';
-- Expected: DELETE 1

-- T6.5: Admin can read the audit log
SELECT COUNT(*) FROM audit_log;
-- Expected: >= 1 (the INSERT/DELETE above should have generated entries)

ROLLBACK;
```

**Pass criteria:** All T6 queries succeed without restriction.

---

### T7 — RLS: No Context = No Data

**Goal:** Queries without calling `set_rls_context` return zero rows (fail-safe default).

```sql
BEGIN;
SET LOCAL ROLE app_customer_role;
-- Intentionally skip set_rls_context

-- T7.1: No rows visible without context
SELECT COUNT(*) FROM users;         -- Expected: 0
SELECT COUNT(*) FROM appointments;  -- Expected: 0
SELECT COUNT(*) FROM orders;        -- Expected: 0

ROLLBACK;
```

**Pass criteria:** All counts return 0, no errors.

---

### T8 — Appointments Workflow

**Goal:** Test the full appointment lifecycle from booking to completion.

```sql
BEGIN;

-- Step 1: Customer books an appointment
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context('<customer1_id>', 'customer', '<branch1_id>');

INSERT INTO appointments (user_id, service_id, branch_id, scheduled_at, status)
VALUES (
    '<customer1_id>',
    (SELECT id FROM services WHERE branch_id = '<branch1_id>' AND is_active = TRUE LIMIT 1),
    '<branch1_id>',
    NOW() + interval '3 days',
    'pending'
)
RETURNING id;
-- Note the returned id as <appt_id>

-- Step 2: Customer cancels it (only allowed from pending/confirmed)
UPDATE appointments
SET status = 'cancelled'
WHERE id = '<appt_id>'
  AND status IN ('pending', 'confirmed')
RETURNING id, status;
-- Expected: status = 'cancelled'

-- Step 3: Customer CANNOT change a cancelled appointment
UPDATE appointments
SET status = 'pending'
WHERE id = '<appt_id>';
-- Expected: UPDATE 0 (RLS USING clause blocks rows with status='cancelled')

ROLLBACK;
```

```sql
-- Step 4: Staff confirms an appointment (separate transaction)
BEGIN;
SET LOCAL ROLE app_staff_role;
SELECT set_rls_context('<staff1_id>', 'staff', '<branch1_id>');

UPDATE appointments
SET status = 'confirmed', notes = 'Confirmed by staff'
WHERE id = '<appt_id>'
RETURNING id, status, notes;
-- Expected: status = 'confirmed'

-- Step 5: Staff marks as completed
UPDATE appointments
SET status = 'completed'
WHERE id = '<appt_id>'
RETURNING id, status;
-- Expected: status = 'completed'

ROLLBACK;
```

**Pass criteria:** Each status transition succeeds or is blocked as designed.

---

### T9 — Orders & Order Items

**Goal:** Verify order creation and item visibility rules.

```sql
BEGIN;
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context('<customer1_id>', 'customer', '<branch1_id>');

-- T9.1: Create an order
INSERT INTO orders (user_id, branch_id, total_amount, status)
VALUES ('<customer1_id>', '<branch1_id>', 0.00, 'pending')
RETURNING id;
-- Note returned id as <order_id>

-- T9.2: Add items to the order
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
VALUES (
    '<order_id>',
    (SELECT id FROM products WHERE is_active = TRUE LIMIT 1),
    2,
    (SELECT price FROM products WHERE is_active = TRUE LIMIT 1)
)
RETURNING id, quantity, unit_price;
-- Expected: INSERT 0 1

-- T9.3: Customer can see their order items
SELECT oi.id, oi.quantity, oi.unit_price
FROM order_items oi
JOIN orders o ON o.id = oi.order_id;
-- Expected: the row just inserted

-- T9.4: Customer CANNOT add items to another customer's order
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT o.id,
       (SELECT id FROM products WHERE is_active = TRUE LIMIT 1),
       1,
       9.99
FROM orders o
WHERE o.user_id != '<customer1_id>'
LIMIT 1;
-- Expected: INSERT 0 0 or policy error depending on whether other orders exist

ROLLBACK;
```

**Pass criteria:** T9.1–T9.3 succeed, T9.4 inserts 0 rows.

---

### T10 — Audit Log

**Goal:** Confirm changes to audited tables are recorded.

```sql
-- Capture current audit count
SELECT COUNT(*) AS before_count FROM audit_log;

-- Make a change as admin (no RLS restriction)
BEGIN;
SET LOCAL ROLE app_admin_role;
SELECT set_rls_context('<admin_id>', 'admin', NULL);

UPDATE users
SET phone = '555-TEST'
WHERE id = '<customer1_id>'
RETURNING id, phone;

COMMIT;

-- Check audit log increased
SELECT COUNT(*) AS after_count FROM audit_log;
-- Expected: after_count = before_count + 1

-- Inspect the entry
SELECT action, table_name, record_id, old_values->>'phone', new_values->>'phone'
FROM audit_log
ORDER BY created_at DESC
LIMIT 1;
-- Expected: action='users.update', old phone vs '555-TEST'

-- T10.2: Customer CANNOT read audit log
BEGIN;
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context('<customer1_id>', 'customer', '<branch1_id>');

SELECT COUNT(*) FROM audit_log;
-- Expected: 0 (RLS hides all rows from non-admins)

ROLLBACK;
```

**Pass criteria:** Audit entry created on UPDATE, customers see 0 audit rows.

---

### T11 — Negative / Security Tests

**Goal:** Confirm that privilege escalation and unauthorized access are blocked.

```sql
-- T11.1: app_service_user cannot become a superuser
SET ROLE postgres;
-- Expected: ERROR: permission denied to set role "postgres"

-- T11.2: Customer cannot DROP a table
BEGIN;
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context('<customer1_id>', 'customer', '<branch1_id>');
DROP TABLE orders;
-- Expected: ERROR: must be owner of table orders
ROLLBACK;

-- T11.3: Customer cannot change their own role column
BEGIN;
SET LOCAL ROLE app_customer_role;
SELECT set_rls_context('<customer1_id>', 'customer', '<branch1_id>');
UPDATE users SET role = 'admin' WHERE id = '<customer1_id>';
-- Expected: either UPDATE 0 or WITH CHECK violation
-- (column-level: the update is allowed through policy but schema should restrict this
--  via application-level validation. Production hardening: add column-level security.)
ROLLBACK;

-- T11.4: Invalid role in set_rls_context raises an error
SELECT set_rls_context('<customer1_id>', 'superuser', NULL);
-- Expected: ERROR: Invalid role: superuser. Must be customer, staff, or admin.

-- T11.5: Staff cannot see another branch's data
BEGIN;
SET LOCAL ROLE app_staff_role;
SELECT set_rls_context('<staff1_id>', 'staff', '<branch2_id>');  -- wrong branch for this staff
SELECT user_id, branch_id FROM appointments WHERE branch_id = '<branch1_id>';
-- Expected: 0 rows
ROLLBACK;
```

**Pass criteria:** All escalation attempts fail, invalid role raises an exception.

---

### T12 — pgAdmin Smoke Test

**Goal:** Verify pgAdmin is accessible and can connect to the database.

1. Open your browser and navigate to `http://localhost:5050` (or the port set in `.env`)
2. Log in with `PGADMIN_EMAIL` and `PGADMIN_PASSWORD` from your `.env` file
3. Register a new server:
   - **Host:** `postgres` (Docker service name)
   - **Port:** `5432`
   - **Database:** `beauty_app`
   - **Username:** `beauty_admin`
   - **Password:** value of `POSTGRES_PASSWORD` in your `.env`
4. Expand **Schemas → public → Tables** — confirm all 8 tables are visible
5. Run a query in the Query Tool:
   ```sql
   SELECT current_database(), current_user, version();
   ```
   Expected: `beauty_app`, `beauty_admin`, `PostgreSQL 16.x`

**Pass criteria:** pgAdmin loads, connects, and shows the correct schema.

---

## Quick Reference

### Connect commands

```bash
# Superuser (schema management)
docker exec -it beauty_app_postgres psql -U beauty_admin -d beauty_app

# Application service user (simulate app behavior)
docker exec -it beauty_app_postgres \
  psql "postgresql://app_service_user:App_S3rvice_P@ss!@localhost/beauty_app"
```

### Useful psql meta-commands

| Command | Description |
|---|---|
| `\dt` | List tables |
| `\d <table>` | Describe table (columns, constraints) |
| `\dp <table>` | Show privileges |
| `\df` | List functions |
| `\dRp` | List RLS policies |
| `\x` | Toggle expanded output |
| `\timing` | Show query execution time |

### Check RLS policies at a glance

```sql
SELECT schemaname, tablename, policyname, roles, cmd, qual
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
```

### Explain a query with RLS

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM appointments;
-- Look for "Filter" nodes showing RLS predicate pushdown
```

### Reset and re-seed

```bash
# Destroy volume and rebuild from scratch
docker compose down -v && docker compose up -d
```
