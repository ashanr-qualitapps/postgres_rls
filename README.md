# beauty_app – PostgreSQL Service

PostgreSQL 16 database for **beauty_app**, running in Docker with full **Row Level Security (RLS)** enforcement. Includes pgAdmin for database management.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Database Architecture](#database-architecture)
- [Row Level Security](#row-level-security)
- [Application Integration](#application-integration)
- [pgAdmin](#pgadmin)
- [Common Commands](#common-commands)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Tool | Minimum Version |
|---|---|
| Docker | 24.x |
| Docker Compose | v2.x (`docker compose` not `docker-compose`) |

---

## Quick Start

```bash
# 1. Clone / enter the directory
cd d:/apps/beauty_app/postgres

# 2. Copy the example env file and fill in your passwords
cp .env.example .env

# 3. Start the stack (detached)
docker compose up -d

# 4. Verify both containers are healthy
docker compose ps

# 5. Connect with psql
docker exec -it beauty_app_postgres \
    psql -U beauty_admin -d beauty_app
```

On first start, Docker runs every file in `init/` in alphabetical order:

```
01_roles.sql       → DB roles
02_extensions.sql  → uuid-ossp, pgcrypto, citext
03_schema.sql      → tables + indexes + triggers
04_functions.sql   → RLS context helpers + audit triggers
05_rls.sql         → RLS ENABLE + all policies
06_grants.sql      → object-level privileges
07_seed.sql        → demo / development data
```

> **Re-init:** Init scripts only run once (on an empty `postgres_data` volume). To re-run them, destroy the volume: `docker compose down -v && docker compose up -d`.

---

## Project Structure

```
postgres/
├── Dockerfile                    # PostgreSQL 16-alpine + contrib extensions
├── docker-compose.yml            # postgres + pgAdmin services
├── .env                          # local credentials  ← gitignored
├── .env.example                  # safe template to commit
├── .gitignore
├── config/
│   └── postgresql.conf           # tuned server configuration
├── init/                         # SQL run automatically on first boot
│   ├── 01_roles.sql
│   ├── 02_extensions.sql
│   ├── 03_schema.sql
│   ├── 04_functions.sql
│   ├── 05_rls.sql
│   └── 06_grants.sql
│   └── 07_seed.sql               # demo data (remove in production)
├── examples/
│   └── rls_usage_examples.sql    # copy-paste test queries
├── README.md
└── SCALABILITY.md
```

---

## Configuration

All secrets live in `.env` (never commit this file):

```dotenv
POSTGRES_DB=beauty_app
POSTGRES_USER=beauty_admin
POSTGRES_PASSWORD=<strong-password>
POSTGRES_PORT=5432

PGADMIN_EMAIL=admin@yourdomain.com
PGADMIN_PASSWORD=<strong-password>
PGADMIN_PORT=5050
```

Server tuning lives in [config/postgresql.conf](config/postgresql.conf). Key values:

| Parameter | Default | Notes |
|---|---|---|
| `shared_buffers` | `256MB` | ~25 % of RAM recommended |
| `max_connections` | `100` | Reduce if using a connection pooler |
| `work_mem` | `4MB` | Increase for analytical queries |
| `row_security` | `on` | Must stay enabled |

---

## Database Architecture

### Tables

| Table | RLS column | Purpose |
|---|---|---|
| `branches` | — | Salon locations |
| `users` | `id`, `branch_id` | Customers, staff, admins |
| `services` | `branch_id` | Treatments offered per branch |
| `appointments` | `user_id`, `branch_id` | Bookings |
| `products` | `branch_id` | Retail items |
| `orders` | `user_id`, `branch_id` | Purchase orders |
| `order_items` | via `order_id` | Line items on orders |
| `audit_log` | `user_id` | Immutable change trail |

### Roles

```
app_readonly        nologin  – SELECT only (reporting)
app_customer_role   nologin  – customer-tier privileges
app_staff_role      nologin  – staff-tier privileges
app_admin_role      nologin  – unrestricted DML
app_service_user    login    – single login used by the app server
```

The application server always connects as `app_service_user`, then issues `SET LOCAL ROLE` per request, keeping the login credentials stable while enforcing per-user data isolation through RLS.

---

## Row Level Security

### How it works

1. **`ENABLE ROW LEVEL SECURITY`** activates the feature on a table.
2. **`FORCE ROW LEVEL SECURITY`** makes it apply even to the table owner.
3. **Policies** define which rows each role can SELECT / INSERT / UPDATE / DELETE.
4. **Session context** (user id, role, branch id) is passed via PostgreSQL configuration parameters scoped to the transaction.

### Calling from your application

Every database transaction **must** begin with `set_rls_context()`:

```sql
BEGIN;

SET LOCAL ROLE app_customer_role;          -- or app_staff_role / app_admin_role
SELECT set_rls_context(
    '<user-uuid>',     -- authenticated user's ID
    'customer',        -- customer | staff | admin
    '<branch-uuid>'    -- required for staff; optional for others
);

-- All queries here are automatically filtered by RLS
SELECT * FROM appointments;   -- returns only this user's rows

COMMIT;
```

`SET LOCAL` means all settings are automatically rolled back at transaction end — no context bleed between requests.

### Policy matrix

| Table | customer | staff | admin |
|---|---|---|---|
| `users` | own row only | branch users | all |
| `branches` | read all | read all | full DML |
| `services` | read active | read branch | full DML |
| `appointments` | own rows | branch rows | all |
| `products` | read active | read branch | full DML |
| `orders` | own rows | branch rows | all |
| `order_items` | via own orders | via branch orders | all |
| `audit_log` | own entries | branch entries | all |

---

## pgAdmin

Once the stack is running, open **http://localhost:5050** and log in with the credentials from `.env`.

Add a server connection:

| Field | Value |
|---|---|
| Host | `postgres` (Docker service name) |
| Port | `5432` |
| Database | `beauty_app` |
| Username | `beauty_admin` |
| Password | value of `POSTGRES_PASSWORD` in `.env` |

---

## Common Commands

```bash
# Start / stop
docker compose up -d
docker compose down

# Destroy all data and re-initialise from scratch
docker compose down -v && docker compose up -d

# Live logs
docker compose logs -f postgres

# Open psql inside the container
docker exec -it beauty_app_postgres psql -U beauty_admin -d beauty_app

# Run a SQL file against the live database
docker exec -i beauty_app_postgres \
    psql -U beauty_admin -d beauty_app \
    < init/07_seed.sql

# Backup
docker exec beauty_app_postgres \
    pg_dump -U beauty_admin beauty_app | gzip > backup_$(date +%F).sql.gz

# Restore
gunzip -c backup_2026-02-25.sql.gz | \
    docker exec -i beauty_app_postgres \
    psql -U beauty_admin beauty_app
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Queries return 0 rows unexpectedly | `set_rls_context()` not called | Always call it inside the transaction before any query |
| `permission denied for table` | Role not granted privileges | Check `init/06_grants.sql` and re-apply |
| Container exits immediately | Bad `.env` variable | Check `docker compose logs postgres` |
| Init scripts not running | Volume already exists | `docker compose down -v` to wipe, then `up -d` |
| pgAdmin can't connect | Wrong host name | Use service name `postgres`, not `localhost` |
