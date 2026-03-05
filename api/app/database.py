import uuid
from contextlib import asynccontextmanager
from typing import AsyncGenerator, Optional

import asyncpg

from app.config import get_settings

_pool: Optional[asyncpg.Pool] = None

# Maps the JWT role claim to the DB group role used by RLS policies.
_ROLE_MAP: dict[str, str] = {
    "customer": "app_customer_role",
    "staff":    "app_staff_role",
    "admin":    "app_admin_role",
}


async def init_pool() -> None:
    global _pool
    s = get_settings()
    _pool = await asyncpg.create_pool(
        host=s.POSTGRES_HOST,
        port=s.POSTGRES_PORT,
        database=s.POSTGRES_DB,
        user=s.APP_DB_USER,
        password=s.APP_DB_PASS,
        min_size=2,
        max_size=20,
        command_timeout=30,
    )


async def close_pool() -> None:
    global _pool
    if _pool:
        await _pool.close()
        _pool = None


def get_pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("Database pool not initialised.")
    return _pool


@asynccontextmanager
async def rls_conn(
    user_id: str,
    role: str,
    branch_id: Optional[str] = None,
) -> AsyncGenerator[asyncpg.Connection, None]:
    """
    Acquire a connection with RLS context scoped to the authenticated user.

    Inside the transaction:
      1. set_rls_context() injects user/role/branch into session variables
         consumed by all RLS policy USING expressions.
      2. SET LOCAL ROLE restricts DML to the matching app role (defence-in-depth).

    Both settings use SET LOCAL so they are automatically cleared when the
    transaction ends, preventing context bleed between pooled connections.
    """
    db_role = _ROLE_MAP.get(role, "app_customer_role")
    async with get_pool().acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                "SELECT set_rls_context($1, $2, $3)",
                uuid.UUID(user_id),
                role,
                uuid.UUID(branch_id) if branch_id else None,
            )
            # SET LOCAL ROLE is safe: db_role comes from our hardcoded dict.
            await conn.execute(f"SET LOCAL ROLE {db_role}")
            yield conn


@asynccontextmanager
async def raw_conn() -> AsyncGenerator[asyncpg.Connection, None]:
    """
    Plain connection for SECURITY DEFINER auth functions.
    No RLS context is set; the called functions bypass RLS internally.
    """
    async with get_pool().acquire() as conn:
        yield conn
