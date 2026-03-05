-- =============================================================================
-- 07_seed.sql
-- Development / demo seed data.
-- DO NOT run this in production.
-- =============================================================================

\echo '>>> [07] Seeding demo data...'

-- ---------------------------------------------------------------------------
-- Branches
-- ---------------------------------------------------------------------------
INSERT INTO branches (id, name, address, phone, timezone) VALUES
    ('11111111-0000-0000-0000-000000000001', 'Downtown Studio',
     '100 Main St, Suite 1',  '+1-555-0101', 'America/New_York'),
    ('11111111-0000-0000-0000-000000000002', 'Uptown Salon',
     '200 Park Ave, Floor 3', '+1-555-0202', 'America/New_York')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Users  (passwords are bcrypt of 'password123' for demo purposes only)
-- ---------------------------------------------------------------------------
INSERT INTO users (id, branch_id, email, password_hash, full_name, phone, role) VALUES
    -- Admin (no branch affiliation)
    ('22222222-0000-0000-0000-000000000001', NULL,
     'admin@beautyapp.com',
     crypt('password123', gen_salt('bf', 12)),
     'Admin User', '+1-555-9001', 'admin'),

    -- Staff at Downtown
    ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
     'staff.downtown@beautyapp.com',
     crypt('password123', gen_salt('bf', 12)),
     'Jane Smith', '+1-555-9002', 'staff'),

    -- Staff at Uptown
    ('22222222-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000002',
     'staff.uptown@beautyapp.com',
     crypt('password123', gen_salt('bf', 12)),
     'Bob Johnson', '+1-555-9003', 'staff'),

    -- Customer A (Downtown branch)
    ('22222222-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000001',
     'alice@example.com',
     crypt('password123', gen_salt('bf', 12)),
     'Alice Brown', '+1-555-1001', 'customer'),

    -- Customer B (Uptown branch)
    ('22222222-0000-0000-0000-000000000005', '11111111-0000-0000-0000-000000000002',
     'charlie@example.com',
     crypt('password123', gen_salt('bf', 12)),
     'Charlie Davis', '+1-555-1002', 'customer')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Services
-- ---------------------------------------------------------------------------
INSERT INTO services (id, branch_id, name, description, duration_min, price, category) VALUES
    -- Downtown services
    ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
     'Classic Haircut', 'Wash, cut and blow-dry', 45, 55.00, 'Hair'),
    ('33333333-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
     'Full Manicure', 'Nail shaping, cuticle care, polish', 60, 40.00, 'Nails'),
    ('33333333-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001',
     'Deep Tissue Massage', '60-minute therapeutic massage', 60, 90.00, 'Massage'),

    -- Uptown services
    ('33333333-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000002',
     'Balayage Color', 'Hand-painted highlights', 120, 180.00, 'Hair'),
    ('33333333-0000-0000-0000-000000000005', '11111111-0000-0000-0000-000000000002',
     'Hydrating Facial', 'Deep cleanse and hydration treatment', 75, 95.00, 'Skin')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Appointments
-- ---------------------------------------------------------------------------
INSERT INTO appointments (id, user_id, staff_id, service_id, branch_id, scheduled_at, status) VALUES
    -- Alice at Downtown with Jane
    ('44444444-0000-0000-0000-000000000001',
     '22222222-0000-0000-0000-000000000004',  -- Alice
     '22222222-0000-0000-0000-000000000002',  -- Jane (staff)
     '33333333-0000-0000-0000-000000000001',  -- Classic Haircut
     '11111111-0000-0000-0000-000000000001',  -- Downtown
     NOW() + INTERVAL '1 day', 'confirmed'),

    -- Charlie at Uptown with Bob
    ('44444444-0000-0000-0000-000000000002',
     '22222222-0000-0000-0000-000000000005',  -- Charlie
     '22222222-0000-0000-0000-000000000003',  -- Bob (staff)
     '33333333-0000-0000-0000-000000000004',  -- Balayage Color
     '11111111-0000-0000-0000-000000000002',  -- Uptown
     NOW() + INTERVAL '2 days', 'pending')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------
INSERT INTO products (id, branch_id, name, sku, price, stock_qty, category) VALUES
    ('55555555-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
     'Argan Oil Shampoo', 'SHP-ARGAN-001', 24.99, 50, 'Hair Care'),
    ('55555555-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
     'Hydrating Conditioner', 'CND-HYD-001', 22.99, 40, 'Hair Care'),
    ('55555555-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000002',
     'Vitamin C Serum', 'SKN-VTC-001', 49.99, 30, 'Skin Care'),
    ('55555555-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000002',
     'SPF 50 Sunscreen', 'SKN-SPF-001', 31.99, 60, 'Skin Care')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Orders + order_items
-- ---------------------------------------------------------------------------
INSERT INTO orders (id, user_id, branch_id, total_amount, status) VALUES
    ('66666666-0000-0000-0000-000000000001',
     '22222222-0000-0000-0000-000000000004',  -- Alice
     '11111111-0000-0000-0000-000000000001',  -- Downtown
     47.98, 'paid')
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    ('66666666-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000001', 1, 24.99),
    ('66666666-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000002', 1, 22.99)
ON CONFLICT DO NOTHING;

\echo '>>> [07] Demo data seeded.'
