import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.database import rls_conn
from app.dependencies import get_current_user, require_role
from app.models.schemas import UserUpdate, AdminUserUpdate, UserResponse

router = APIRouter(prefix="/users", tags=["users"])

_staff_or_admin = require_role("staff", "admin")
_admin = require_role("admin")


@router.get("/me", response_model=UserResponse)
async def get_my_profile(current_user: dict = Depends(get_current_user)):
    """Return the currently authenticated user's profile."""
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            "SELECT * FROM users WHERE id = $1::uuid",
            uuid.UUID(current_user["user_id"]),
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return UserResponse.model_validate(dict(row))


@router.patch("/me", response_model=UserResponse)
async def update_my_profile(
    body: UserUpdate,
    current_user: dict = Depends(get_current_user),
):
    """Update own profile (full_name, phone). Role and branch changes require admin."""
    updates = body.model_dump(exclude_none=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No fields to update",
        )
    set_clause = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(updates))
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            f"UPDATE users SET {set_clause} WHERE id = $1::uuid RETURNING *",
            uuid.UUID(current_user["user_id"]), *updates.values(),
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return UserResponse.model_validate(dict(row))


@router.get("/", response_model=list[UserResponse])
async def list_users(
    branch_id: str | None = Query(None),
    role: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(_staff_or_admin),
):
    """
    List users (staff and admin only).
    RLS limits staff to their own branch; admins see all.
    """
    conditions, params = [], []

    if branch_id:
        params.append(branch_id)
        conditions.append(f"branch_id = ${len(params)}::uuid")

    if role:
        params.append(role)
        conditions.append(f"role = ${len(params)}")

    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
    params += [limit, offset]

    async with rls_conn(**current_user) as conn:
        rows = await conn.fetch(
            f"""
            SELECT * FROM users {where}
            ORDER BY full_name
            LIMIT ${len(params)-1} OFFSET ${len(params)}
            """,
            *params,
        )
    return [UserResponse.model_validate(dict(r)) for r in rows]


@router.get("/{user_id}", response_model=UserResponse)
async def get_user(
    user_id: str,
    current_user: dict = Depends(get_current_user),
):
    """
    Get a user by ID.
    Customers can only retrieve their own profile; staff/admin can retrieve any.
    RLS enforces this at the DB level.
    """
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            "SELECT * FROM users WHERE id = $1::uuid", user_id
        )
    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found or you lack permission to view it",
        )
    return UserResponse.model_validate(dict(row))


@router.patch("/{user_id}", response_model=UserResponse)
async def admin_update_user(
    user_id: str,
    body: AdminUserUpdate,
    current_user: dict = Depends(_admin),
):
    """Update any user's profile, role, branch, or active status (admin only)."""
    updates = body.model_dump(exclude_none=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No fields to update",
        )
    set_clause = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(updates))
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            f"UPDATE users SET {set_clause} WHERE id = $1::uuid RETURNING *",
            user_id, *updates.values(),
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return UserResponse.model_validate(dict(row))
