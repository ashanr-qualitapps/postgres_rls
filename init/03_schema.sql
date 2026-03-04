-- =============================================================================
-- 03_schema.sql
-- Core schema for the beauty_app.
-- Every table that holds per-user data carries a user_id (UUID) column
-- which the RLS policies use to enforce row-level isolation.
-- =============================================================================

\echo '>>> [03] Creating schema...'

-- ---------------------------------------------------------------------------
-- Utility: updated_at auto-stamp trigger function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. BRANCHES  (salon locations)
--    Visible to everyone; only admins can INSERT/UPDATE/DELETE via RLS.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS branches (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(120) NOT NULL,
    address     TEXT,
    phone       VARCHAR(30),
    timezone    VARCHAR(60)  NOT NULL DEFAULT 'UTC',
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TRIGGER set_branches_updated_at
    BEFORE UPDATE ON branches
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. USERS  (customers, staff, admins)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id            UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id     UUID        REFERENCES branches(id) ON DELETE SET NULL,
    email         CITEXT      NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,
    full_name     VARCHAR(150) NOT NULL,
    phone         VARCHAR(30),
    -- 'customer' | 'staff' | 'admin'
    role          VARCHAR(20)  NOT NULL DEFAULT 'customer'
                               CHECK (role IN ('customer', 'staff', 'admin')),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_email     ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_branch_id ON users (branch_id);
CREATE INDEX IF NOT EXISTS idx_users_role      ON users (role);

CREATE TRIGGER set_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. SERVICES  (treatments / services offered)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS services (
    id           UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id    UUID         REFERENCES branches(id) ON DELETE CASCADE,
    name         VARCHAR(150) NOT NULL,
    description  TEXT,
    duration_min INT          NOT NULL DEFAULT 60 CHECK (duration_min > 0),
    price        NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    category     VARCHAR(60),
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_services_branch_id ON services (branch_id);

CREATE TRIGGER set_services_updated_at
    BEFORE UPDATE ON services
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. APPOINTMENTS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS appointments (
    id           UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    -- The customer who booked
    user_id      UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Staff member assigned (optional)
    staff_id     UUID         REFERENCES users(id)  ON DELETE SET NULL,
    service_id   UUID         NOT NULL REFERENCES services(id) ON DELETE RESTRICT,
    branch_id    UUID         NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
    scheduled_at TIMESTAMPTZ  NOT NULL,
    duration_min INT          NOT NULL DEFAULT 60,
    status       VARCHAR(20)  NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending','confirmed','completed','cancelled','no_show')),
    notes        TEXT,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_appointments_user_id    ON appointments (user_id);
CREATE INDEX IF NOT EXISTS idx_appointments_staff_id   ON appointments (staff_id);
CREATE INDEX IF NOT EXISTS idx_appointments_branch_id  ON appointments (branch_id);
CREATE INDEX IF NOT EXISTS idx_appointments_scheduled  ON appointments (scheduled_at);

CREATE TRIGGER set_appointments_updated_at
    BEFORE UPDATE ON appointments
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. PRODUCTS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS products (
    id           UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id    UUID          REFERENCES branches(id) ON DELETE SET NULL,
    name         VARCHAR(150)  NOT NULL,
    description  TEXT,
    sku          VARCHAR(60)   UNIQUE,
    price        NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    stock_qty    INT           NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),
    category     VARCHAR(60),
    is_active    BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_products_branch_id ON products (branch_id);

CREATE TRIGGER set_products_updated_at
    BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. ORDERS  (retail purchases)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orders (
    id           UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id      UUID          NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    branch_id    UUID          NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0),
    status       VARCHAR(20)   NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('pending','paid','shipped','delivered','cancelled','refunded')),
    notes        TEXT,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_user_id   ON orders (user_id);
CREATE INDEX IF NOT EXISTS idx_orders_branch_id ON orders (branch_id);
CREATE INDEX IF NOT EXISTS idx_orders_status    ON orders (status);

CREATE TRIGGER set_orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ---------------------------------------------------------------------------
-- 7. ORDER ITEMS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS order_items (
    id          UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id    UUID          NOT NULL REFERENCES orders(id)    ON DELETE CASCADE,
    product_id  UUID          NOT NULL REFERENCES products(id)  ON DELETE RESTRICT,
    quantity    INT           NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_order_items_order_id   ON order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON order_items (product_id);

-- ---------------------------------------------------------------------------
-- 8. AUDIT LOG  (tamper-evident; RLS = append-only for non-admins)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id          BIGSERIAL     PRIMARY KEY,
    user_id     UUID,
    action      VARCHAR(60)   NOT NULL,  -- e.g. 'appointment.create'
    table_name  VARCHAR(60),
    record_id   UUID,
    old_values  JSONB,
    new_values  JSONB,
    ip_address  INET,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_user_id    ON audit_log (user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log (created_at DESC);

\echo '>>> [03] Schema created.'
