# Scalability Guide – beauty_app PostgreSQL

This document covers strategies for scaling the beauty_app PostgreSQL tier from a single Docker container to a production-grade, high-availability setup.

---

## Table of Contents

1. [Connection Management](#1-connection-management)
2. [Vertical Scaling](#2-vertical-scaling)
3. [Read Replicas & Streaming Replication](#3-read-replicas--streaming-replication)
4. [Connection Pooling with PgBouncer](#4-connection-pooling-with-pgbouncer)
5. [Partitioning](#5-partitioning)
6. [Indexing Strategy](#6-indexing-strategy)
7. [Caching Layer](#7-caching-layer)
8. [Horizontal Sharding (Advanced)](#8-horizontal-sharding-advanced)
9. [Backup & Point-in-Time Recovery](#9-backup--point-in-time-recovery)
10. [Monitoring](#10-monitoring)
11. [RLS at Scale](#11-rls-at-scale)
12. [Migration Path: Single Node → HA Cluster](#12-migration-path-single-node--ha-cluster)

---

## 1. Connection Management

Each PostgreSQL connection spawns a backend process (~5–10 MB RAM). Unmanaged connection growth is the most common cause of performance degradation.

### Current limits (config/postgresql.conf)

```
max_connections = 100
```

### Recommendations by load tier

| Daily active users | Strategy |
|---|---|
| < 500 | Default settings + application-side connection pool |
| 500 – 5,000 | PgBouncer in transaction mode (see §4) |
| 5,000 – 50,000 | PgBouncer cluster + read replicas |
| 50,000+ | Citus or managed cloud PG (AWS Aurora, Neon, Supabase) |

### Application-side pool settings (example: Node.js pg-pool)

```js
const pool = new Pool({
  max: 10,            // max connections per app instance
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 2_000,
});
```

---

## 2. Vertical Scaling

Before any architectural changes, tune `postgresql.conf` to match the host's RAM and CPU.

### RAM-based tuning formula

| Parameter | Formula | 4 GB RAM | 8 GB RAM | 16 GB RAM |
|---|---|---|---|---|
| `shared_buffers` | 25 % of RAM | 1 GB | 2 GB | 4 GB |
| `effective_cache_size` | 75 % of RAM | 3 GB | 6 GB | 12 GB |
| `work_mem` | RAM ÷ (max_connections × 2) | 20 MB | 40 MB | 80 MB |
| `maintenance_work_mem` | 5 % of RAM | 200 MB | 400 MB | 800 MB |

Update `config/postgresql.conf` and restart:

```bash
docker compose restart postgres
```

### CPU-bound workloads

```
# config/postgresql.conf
max_worker_processes = 8          # = CPU cores
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
parallel_leader_participation = on
```

---

## 3. Read Replicas & Streaming Replication

Offload reporting, analytics, and read-heavy API endpoints to one or more read replicas.

### docker-compose.replica.yml

Add this overlay to your stack:

```yaml
services:
  postgres_replica:
    image: postgres:16-alpine
    container_name: beauty_app_postgres_replica
    restart: unless-stopped
    environment:
      PGUSER: replicator
      PGPASSWORD: ${REPLICATION_PASSWORD}
    volumes:
      - postgres_replica_data:/var/lib/postgresql/data
    command: |
      bash -c "
        until pg_basebackup -h postgres -U replicator -D /var/lib/postgresql/data -P -Xs -R; do
          echo 'Waiting for primary...'; sleep 2;
        done
        postgres
      "
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - beauty_net

volumes:
  postgres_replica_data:
    driver: local
```

### Steps to enable replication on the primary

```sql
-- Run once on primary as beauty_admin
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong-repl-pass';

-- pg_hba.conf (add inside the container or via init script)
-- host replication replicator 0.0.0.0/0 scram-sha-256
```

```
# config/postgresql.conf (primary)
wal_level = replica
max_wal_senders = 5
wal_keep_size = 256MB
hot_standby = on
```

### Routing reads to the replica

Direct read-only queries (reports, dashboards) to the replica connection string. RLS policies **also apply on replicas** — no extra configuration needed.

```
# Primary  (writes + important reads)
postgresql://app_service_user:***@localhost:5432/beauty_app

# Replica  (reports, analytics)
postgresql://app_service_user:***@localhost:5433/beauty_app
```

---

## 4. Connection Pooling with PgBouncer

PgBouncer sits between the application and PostgreSQL, multiplexing many short-lived application connections onto a small number of server connections.

### Add PgBouncer to docker-compose.yml

```yaml
  pgbouncer:
    image: bitnami/pgbouncer:latest
    container_name: beauty_app_pgbouncer
    restart: unless-stopped
    environment:
      POSTGRESQL_HOST: postgres
      POSTGRESQL_PORT: 5432
      POSTGRESQL_DATABASE: beauty_app
      PGBOUNCER_DATABASE: beauty_app
      POSTGRESQL_USERNAME: app_service_user
      POSTGRESQL_PASSWORD: ${APP_SERVICE_PASSWORD}
      PGBOUNCER_POOL_MODE: transaction        # required for SET LOCAL to work
      PGBOUNCER_MAX_CLIENT_CONN: 1000
      PGBOUNCER_DEFAULT_POOL_SIZE: 20
    ports:
      - "6432:6432"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - beauty_net
```

### Pool mode and RLS

Use **`transaction` pool mode** (not `session` mode). In transaction mode, each transaction gets a server connection from the pool; `SET LOCAL` ensures the RLS context is scoped to that transaction and is cleaned up automatically.

**Never use `statement` pool mode** — it breaks multi-statement transactions.

### Application connection string with PgBouncer

```
postgresql://app_service_user:***@localhost:6432/beauty_app
```

---

## 5. Partitioning

Partition large, time-series tables to speed up range scans and simplify data retention.

### Partition `appointments` by month

```sql
-- Convert to partitioned table (run during a maintenance window)
CREATE TABLE appointments_partitioned (
    LIKE appointments INCLUDING ALL
) PARTITION BY RANGE (scheduled_at);

-- Create monthly partitions
CREATE TABLE appointments_2026_01
    PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

CREATE TABLE appointments_2026_02
    PARTITION OF appointments_partitioned
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
-- ... repeat or use pg_partman extension for automation
```

### Partition `audit_log` by month (high-volume table)

```sql
CREATE TABLE audit_log_partitioned (
    LIKE audit_log INCLUDING ALL
) PARTITION BY RANGE (created_at);

-- Automate with pg_partman
SELECT partman.create_parent(
    p_parent_table := 'public.audit_log_partitioned',
    p_control      := 'created_at',
    p_type         := 'range',
    p_interval     := 'monthly'
);
```

### RLS on partitioned tables

Apply `ENABLE ROW LEVEL SECURITY` and all policies to the **parent** table only. PostgreSQL automatically inherits them on every partition.

---

## 6. Indexing Strategy

### Existing indexes (from 03_schema.sql)

All foreign keys and common filter columns are already indexed:
`idx_appointments_user_id`, `idx_appointments_branch_id`, `idx_orders_user_id`, etc.

### Additional indexes for scale

```sql
-- Covering index for appointment list API (avoids heap fetch)
CREATE INDEX idx_appointments_user_status_scheduled
    ON appointments (user_id, status, scheduled_at DESC)
    INCLUDE (service_id, branch_id);

-- Partial index – only future/active appointments
CREATE INDEX idx_appointments_upcoming
    ON appointments (scheduled_at)
    WHERE status IN ('pending', 'confirmed')
      AND scheduled_at > NOW();

-- GIN index for JSONB audit log searches
CREATE INDEX idx_audit_log_new_values_gin
    ON audit_log USING gin (new_values);

-- Trigram index on full_name for LIKE search
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_users_fullname_trgm
    ON users USING gin (full_name gin_trgm_ops);
```

### Identify missing indexes in production

```sql
-- Queries lacking index support (sequential scans on large tables)
SELECT
    schemaname, tablename, attname,
    n_distinct, correlation
FROM pg_stats
WHERE tablename IN ('appointments','orders','users','audit_log')
ORDER BY n_distinct DESC;

-- Unused indexes (candidates for removal)
SELECT indexrelid::regclass, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND schemaname = 'public';
```

---

## 7. Caching Layer

Reduce database load by caching frequently-read, low-change data in Redis or Memcached.

### What to cache

| Data | TTL | Reason |
|---|---|---|
| Branch list | 5 min | Changes rarely; read on every page load |
| Active services list | 2 min | Product catalogue |
| User profile | 30 s | Read-heavy; invalidate on UPDATE |
| Appointment availability slots | 10 s | Real-time but tolerable lag |

### Application-level cache pattern (pseudo-code)

```ts
async function getActiveServices(branchId: string) {
  const cacheKey = `services:${branchId}`;
  const cached = await redis.get(cacheKey);
  if (cached) return JSON.parse(cached);

  // Fall through to PostgreSQL (RLS applies normally)
  const rows = await db.query(
    'SELECT id, name, price FROM services WHERE branch_id = $1 AND is_active',
    [branchId]
  );
  await redis.setex(cacheKey, 120, JSON.stringify(rows));
  return rows;
}
```

> RLS is enforced on the DB side. The cache stores the **role-filtered** result, so cache keys must include the role/branch context.

---

## 8. Horizontal Sharding (Advanced)

For very large multi-tenant deployments (hundreds of branches, millions of users), consider **Citus** (PostgreSQL extension) or a fully managed service.

### Citus distribution strategy

```sql
-- Install Citus extension
CREATE EXTENSION citus;

-- Distribute the largest tables by branch_id (the natural shard key)
SELECT create_distributed_table('appointments', 'branch_id');
SELECT create_distributed_table('orders',       'branch_id');
SELECT create_distributed_table('order_items',  'branch_id');  -- co-locate with orders

-- Reference tables (small, replicated to all shards)
SELECT create_reference_table('branches');
SELECT create_reference_table('services');
```

### Citus + RLS

Citus respects PostgreSQL RLS policies on each shard. The `set_rls_context()` function works without modification because `SET LOCAL` propagates to the worker nodes within the same distributed transaction.

---

## 9. Backup & Point-in-Time Recovery

### Continuous WAL archiving (production requirement)

```
# config/postgresql.conf
archive_mode = on
archive_command = 'aws s3 cp %p s3://beauty-app-wal-archive/%f'
# or: 'cp %p /mnt/wal_archive/%f'
restore_command = 'aws s3 cp s3://beauty-app-wal-archive/%f %p'
```

### Scheduled logical backup script

```bash
#!/usr/bin/env bash
# Save as: scripts/backup.sh
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups"
DB_NAME="beauty_app"

docker exec beauty_app_postgres \
    pg_dump -U beauty_admin \
    --format=custom \
    --compress=9 \
    "$DB_NAME" > "${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.dump"

# Keep only the last 14 days
find "$BACKUP_DIR" -name "*.dump" -mtime +14 -delete
echo "Backup complete: ${DB_NAME}_${TIMESTAMP}.dump"
```

Schedule with cron:

```cron
0 2 * * * /bin/bash /path/to/scripts/backup.sh >> /var/log/pg_backup.log 2>&1
```

### Point-in-time restore

```bash
# Restore to a specific timestamp using pg_restore + WAL replay
pg_restore -U beauty_admin -d beauty_app_restored backup_20260225.dump
```

---

## 10. Monitoring

### Expose PostgreSQL metrics to Prometheus

Add to `docker-compose.yml`:

```yaml
  postgres_exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: beauty_app_pg_exporter
    restart: unless-stopped
    environment:
      DATA_SOURCE_NAME: "postgresql://beauty_admin:${POSTGRES_PASSWORD}@postgres:5432/beauty_app?sslmode=disable"
    ports:
      - "9187:9187"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - beauty_net
```

### Key metrics to alert on

| Metric | Alert threshold |
|---|---|
| `pg_stat_activity_count` > `max_connections * 0.80` | Connection saturation |
| `pg_stat_bgwriter_checkpoints_req_total` rising | WAL checkpoint pressure (increase `max_wal_size`) |
| `pg_stat_user_tables_seq_scan` rising | Missing index (review query plans) |
| `pg_replication_lag` > 5 s | Replica falling behind |
| `pg_database_size_bytes` > 80 % disk | Disk pressure |

### Useful diagnostic queries

```sql
-- Long-running queries
SELECT pid, now() - pg_stat_activity.query_start AS duration,
       query, state
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > INTERVAL '5 seconds'
  AND state <> 'idle';

-- Table bloat estimate
SELECT tablename,
       pg_size_pretty(pg_total_relation_size(tablename::regclass)) AS total_size,
       pg_size_pretty(pg_relation_size(tablename::regclass))        AS table_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(tablename::regclass) DESC;

-- Lock wait chains
SELECT blocked.pid, blocking.pid AS blocking_pid,
       blocked.query, blocking.query AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
```

---

## 11. RLS at Scale

### Index the RLS predicate columns

The RLS `USING` expressions become implicit `WHERE` clauses. Ensure every column used in a policy is indexed:

```sql
-- Already present in 03_schema.sql, verify all exist:
\d appointments          -- confirm user_id, branch_id indexes
\d orders                -- confirm user_id, branch_id indexes
```

### Use `SECURITY BARRIER` views for complex policies

For reporting views that join multiple RLS-protected tables, wrap them in a `SECURITY BARRIER` view to prevent predicate push-down leaking data:

```sql
CREATE VIEW customer_portal
    WITH (security_barrier = true) AS
SELECT
    a.id, a.scheduled_at, a.status,
    s.name AS service_name,
    b.name AS branch_name
FROM appointments a
JOIN services  s ON s.id = a.service_id
JOIN branches  b ON b.id = a.branch_id;

GRANT SELECT ON customer_portal TO app_customer_role;
```

### Avoid `SECURITY DEFINER` functions inside hot paths

`SECURITY DEFINER` functions bypass RLS for the caller. The `set_rls_context()` and `record_audit_event()` functions use it intentionally and minimally. Do not add new `SECURITY DEFINER` functions unless absolutely necessary.

### Profile RLS overhead

```sql
-- Compare plans with and without RLS context
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM appointments WHERE user_id = current_app_user_id();
```

If the plan shows a sequential scan instead of an index scan, confirm the index on `user_id` exists and that the query planner is picking it up.

---

## 12. Migration Path: Single Node → HA Cluster

```
Phase 1 (current)
  Docker single-node
  ↓  tune postgresql.conf
  ↓  add PgBouncer (§4)

Phase 2 (1 k – 10 k DAU)
  Add streaming read replica (§3)
  Route reporting traffic to replica
  Schedule automated backups (§9)

Phase 3 (10 k – 100 k DAU)
  Promote to managed cloud PG
  (AWS RDS Multi-AZ / Aurora / Supabase)
  Enable WAL archiving for PITR
  Add Prometheus + Grafana (§10)
  Partition audit_log and appointments (§5)

Phase 4 (100 k+ DAU)
  Citus distributed tables sharded by branch_id (§8)
  Or migrate to Neon / Supabase for serverless scaling
  Redis caching for catalogue data (§7)
  PgBouncer cluster with multiple nodes
```

> At every phase, the **RLS model remains unchanged** — only infrastructure changes. The `set_rls_context()` API contract is stable across all tiers.
