-- =============================================================================
-- 08_auth_functions.sql
-- SECURITY DEFINER functions for authentication and atomic order placement.
--
-- These functions are owned by the PostgreSQL superuser (the role that runs
-- the init scripts), so SECURITY DEFINER executes with superuser privileges
-- and therefore bypasses FORCE RLS on all tables.
--
-- They are the ONLY backdoors into the data that bypass RLS, and each one
-- validates its inputs before touching any data.
-- =============================================================================

\echo '>>> [08] Creating auth / order functions...'

-- ---------------------------------------------------------------------------
-- authenticate_user
-- Returns the user row if (email, plaintext-password) match; empty otherwise.
-- Uses pgcrypto crypt() so the password is never compared in plaintext.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION authenticate_user(
    p_email    TEXT,
    p_password TEXT
)
RETURNS TABLE (
    id          UUID,
    branch_id   UUID,
    email       TEXT,
    full_name   TEXT,
    phone       TEXT,
    role        TEXT,
    is_active   BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.branch_id,
        u.email::TEXT,
        u.full_name::TEXT,
        u.phone::TEXT,
        u.role::TEXT,
        u.is_active
    FROM users u
    WHERE u.email            = p_email::CITEXT
      AND u.password_hash    = crypt(p_password, u.password_hash)
      AND u.is_active        = TRUE;
END;
$$;

COMMENT ON FUNCTION authenticate_user IS
    'Credential check for the login endpoint. '
    'Returns user data on success, empty set on failure. SECURITY DEFINER.';

-- ---------------------------------------------------------------------------
-- register_user
-- Inserts a new customer account.  Raises P0001 if email already in use.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION register_user(
    p_email     TEXT,
    p_password  TEXT,
    p_full_name TEXT,
    p_phone     TEXT    DEFAULT NULL,
    p_branch_id UUID    DEFAULT NULL
)
RETURNS TABLE (
    id          UUID,
    branch_id   UUID,
    email       TEXT,
    full_name   TEXT,
    phone       TEXT,
    role        TEXT,
    is_active   BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id UUID;
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE email = p_email::CITEXT) THEN
        RAISE EXCEPTION 'EmailAlreadyRegistered'
            USING ERRCODE = 'P0001', DETAIL = p_email;
    END IF;

    INSERT INTO users (email, password_hash, full_name, phone, branch_id, role)
    VALUES (
        p_email::CITEXT,
        crypt(p_password, gen_salt('bf', 12)),
        p_full_name,
        p_phone,
        p_branch_id,
        'customer'
    )
    RETURNING users.id INTO v_id;

    RETURN QUERY
    SELECT
        u.id,
        u.branch_id,
        u.email::TEXT,
        u.full_name::TEXT,
        u.phone::TEXT,
        u.role::TEXT,
        u.is_active
    FROM users u
    WHERE u.id = v_id;
END;
$$;

COMMENT ON FUNCTION register_user IS
    'Create a new customer account from the public register endpoint. '
    'SECURITY DEFINER so RLS INSERT restriction is bypassed safely.';

-- ---------------------------------------------------------------------------
-- place_order
-- Atomic: validates stock, creates order + items, deducts product stock.
-- Uses SELECT FOR UPDATE to prevent concurrent overselling.
-- p_items JSONB format: [{"product_id": "<uuid>", "quantity": <int>}, ...]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION place_order(
    p_user_id   UUID,
    p_branch_id UUID,
    p_notes     TEXT,
    p_items     JSONB
)
RETURNS TABLE (
    order_id     UUID,
    total_amount NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_order_id   UUID;
    v_total      NUMERIC := 0;
    v_item       JSONB;
    v_product_id UUID;
    v_qty        INT;
    v_price      NUMERIC;
    v_stock      INT;
BEGIN
    IF jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Order must contain at least one item'
            USING ERRCODE = 'P0004';
    END IF;

    -- Pass 1: validate every product and lock rows to prevent overselling
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_product_id := (v_item ->> 'product_id')::UUID;
        v_qty        := (v_item ->> 'quantity')::INT;

        IF v_qty < 1 THEN
            RAISE EXCEPTION 'Quantity must be >= 1 for product %', v_product_id
                USING ERRCODE = 'P0004';
        END IF;

        SELECT price, stock_qty
          INTO v_price, v_stock
          FROM products
         WHERE id = v_product_id AND is_active = TRUE
         FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Product % not found or inactive', v_product_id
                USING ERRCODE = 'P0002';
        END IF;

        IF v_stock < v_qty THEN
            RAISE EXCEPTION 'Insufficient stock for product %: available %, requested %',
                v_product_id, v_stock, v_qty
                USING ERRCODE = 'P0003';
        END IF;

        v_total := v_total + (v_price * v_qty);
    END LOOP;

    -- Create the order header
    INSERT INTO orders (user_id, branch_id, total_amount, notes)
    VALUES (p_user_id, p_branch_id, v_total, p_notes)
    RETURNING id INTO v_order_id;

    -- Pass 2: insert line items and deduct stock
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_product_id := (v_item ->> 'product_id')::UUID;
        v_qty        := (v_item ->> 'quantity')::INT;

        SELECT price INTO v_price FROM products WHERE id = v_product_id;

        INSERT INTO order_items (order_id, product_id, quantity, unit_price)
        VALUES (v_order_id, v_product_id, v_qty, v_price);

        UPDATE products
           SET stock_qty = stock_qty - v_qty
         WHERE id = v_product_id;
    END LOOP;

    RETURN QUERY SELECT v_order_id, v_total;
END;
$$;

COMMENT ON FUNCTION place_order IS
    'Atomically validates stock, creates order+items, deducts stock. '
    'SECURITY DEFINER; caller must pass the authenticated user_id.';

-- ---------------------------------------------------------------------------
-- Grant EXECUTE to app_service_user (called before any SET LOCAL ROLE)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION authenticate_user(TEXT, TEXT)
    TO app_service_user;

GRANT EXECUTE ON FUNCTION register_user(TEXT, TEXT, TEXT, TEXT, UUID)
    TO app_service_user;

GRANT EXECUTE ON FUNCTION place_order(UUID, UUID, TEXT, JSONB)
    TO app_service_user;

\echo '>>> [08] Auth / order functions created.'
