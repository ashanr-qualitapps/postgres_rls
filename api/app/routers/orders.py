import json
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.database import raw_conn, rls_conn
from app.dependencies import get_current_user, require_role
from app.models.schemas import OrderCreate, OrderUpdate, OrderResponse

router = APIRouter(prefix="/orders", tags=["orders"])

_staff_or_admin = require_role("staff", "admin")


@router.get("/", response_model=list[OrderResponse])
async def list_orders(
    branch_id: str | None = Query(None),
    order_status: str | None = Query(None, alias="status"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
):
    """
    List orders. RLS enforces visibility:
    - customers see their own orders
    - staff see all orders at their branch
    - admins see everything
    """
    conditions, params = [], []

    if branch_id:
        params.append(branch_id)
        conditions.append(f"o.branch_id = ${len(params)}::uuid")

    if order_status:
        params.append(order_status)
        conditions.append(f"o.status = ${len(params)}")

    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
    params += [limit, offset]

    async with rls_conn(**current_user) as conn:
        rows = await conn.fetch(
            f"""
            SELECT
                o.*,
                COALESCE(
                    json_agg(
                        json_build_object(
                            'id',         oi.id,
                            'product_id', oi.product_id,
                            'quantity',   oi.quantity,
                            'unit_price', oi.unit_price
                        )
                    ) FILTER (WHERE oi.id IS NOT NULL),
                    '[]'
                ) AS items
            FROM orders o
            LEFT JOIN order_items oi ON oi.order_id = o.id
            {where}
            GROUP BY o.id
            ORDER BY o.created_at DESC
            LIMIT ${len(params)-1} OFFSET ${len(params)}
            """,
            *params,
        )

    return [_parse_order(r) for r in rows]


@router.get("/{order_id}", response_model=OrderResponse)
async def get_order(
    order_id: str,
    current_user: dict = Depends(get_current_user),
):
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            """
            SELECT
                o.*,
                COALESCE(
                    json_agg(
                        json_build_object(
                            'id',         oi.id,
                            'product_id', oi.product_id,
                            'quantity',   oi.quantity,
                            'unit_price', oi.unit_price
                        )
                    ) FILTER (WHERE oi.id IS NOT NULL),
                    '[]'
                ) AS items
            FROM orders o
            LEFT JOIN order_items oi ON oi.order_id = o.id
            WHERE o.id = $1::uuid
            GROUP BY o.id
            """,
            order_id,
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Order not found")
    return _parse_order(row)


@router.post("/", response_model=OrderResponse, status_code=status.HTTP_201_CREATED)
async def place_order(
    body: OrderCreate,
    current_user: dict = Depends(get_current_user),
):
    """
    Place an order.  Uses the SECURITY DEFINER place_order() DB function which
    validates stock, inserts order + items, and deducts stock atomically using
    SELECT FOR UPDATE to prevent race conditions.
    """
    if not body.items:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Order must contain at least one item",
        )

    items_json = json.dumps(
        [{"product_id": str(it.product_id), "quantity": it.quantity} for it in body.items]
    )

    # place_order is SECURITY DEFINER – call via raw_conn (no RLS context needed).
    async with raw_conn() as conn:
        try:
            result = await conn.fetchrow(
                "SELECT * FROM place_order($1, $2, $3, $4::jsonb)",
                uuid.UUID(current_user["user_id"]),
                body.branch_id,
                body.notes,
                items_json,
            )
        except Exception as exc:
            err = str(exc)
            if "P0002" in err or "not found or inactive" in err:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc))
            if "P0003" in err or "Insufficient stock" in err:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))
            raise

    # Fetch the full order (with items) via an RLS-scoped connection
    return await get_order(str(result["order_id"]), current_user)


@router.patch("/{order_id}", response_model=OrderResponse)
async def update_order(
    order_id: str,
    body: OrderUpdate,
    current_user: dict = Depends(_staff_or_admin),
):
    """Update order status / notes (staff and admin only)."""
    updates = body.model_dump(exclude_none=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No fields to update",
        )
    set_clause = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(updates))
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            f"UPDATE orders SET {set_clause} WHERE id = $1::uuid RETURNING id",
            order_id, *updates.values(),
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Order not found")
    return await get_order(order_id, current_user)


# ─── helpers ─────────────────────────────────────────────────────────────────

def _parse_order(row) -> OrderResponse:
    data = dict(row)
    raw_items = data.pop("items", "[]")
    if isinstance(raw_items, str):
        raw_items = json.loads(raw_items)
    data["items"] = raw_items
    return OrderResponse.model_validate(data)
