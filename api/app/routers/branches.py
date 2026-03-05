from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.database import rls_conn
from app.dependencies import get_current_user, require_role
from app.models.schemas import BranchCreate, BranchUpdate, BranchResponse

router = APIRouter(prefix="/branches", tags=["branches"])

_admin = require_role("admin")


@router.get("/", response_model=list[BranchResponse])
async def list_branches(
    active_only: bool = Query(True, description="Filter to active branches only"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
):
    """List branches. Visible to all authenticated users."""
    where = "WHERE is_active = TRUE" if active_only else ""
    async with rls_conn(**current_user) as conn:
        rows = await conn.fetch(
            f"SELECT * FROM branches {where} ORDER BY name LIMIT $1 OFFSET $2",
            limit, offset,
        )
    return [BranchResponse.model_validate(dict(r)) for r in rows]


@router.get("/{branch_id}", response_model=BranchResponse)
async def get_branch(
    branch_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Get a single branch by ID."""
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            "SELECT * FROM branches WHERE id = $1::uuid", branch_id
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Branch not found")
    return BranchResponse.model_validate(dict(row))


@router.post("/", response_model=BranchResponse, status_code=status.HTTP_201_CREATED)
async def create_branch(
    body: BranchCreate,
    current_user: dict = Depends(_admin),
):
    """Create a new branch (admin only)."""
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO branches (name, address, phone, timezone)
            VALUES ($1, $2, $3, $4)
            RETURNING *
            """,
            body.name, body.address, body.phone, body.timezone,
        )
    return BranchResponse.model_validate(dict(row))


@router.patch("/{branch_id}", response_model=BranchResponse)
async def update_branch(
    branch_id: str,
    body: BranchUpdate,
    current_user: dict = Depends(_admin),
):
    """Update branch fields (admin only)."""
    updates = body.model_dump(exclude_none=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No fields to update",
        )
    # Field names come from our Pydantic model – safe to interpolate.
    set_clause = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(updates))
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            f"UPDATE branches SET {set_clause} WHERE id = $1::uuid RETURNING *",
            branch_id, *updates.values(),
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Branch not found")
    return BranchResponse.model_validate(dict(row))


@router.delete("/{branch_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_branch(
    branch_id: str,
    current_user: dict = Depends(_admin),
):
    """Permanently delete a branch (admin only). Use PATCH is_active=false to soft-delete."""
    async with rls_conn(**current_user) as conn:
        result = await conn.execute(
            "DELETE FROM branches WHERE id = $1::uuid", branch_id
        )
    if result == "DELETE 0":
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Branch not found")
