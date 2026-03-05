from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.database import rls_conn
from app.dependencies import get_current_user, require_role
from app.models.schemas import ProductCreate, ProductUpdate, ProductResponse

router = APIRouter(prefix="/products", tags=["products"])

_admin = require_role("admin")


@router.get("/", response_model=list[ProductResponse])
async def list_products(
    branch_id: str | None = Query(None),
    category: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
):
    """
    List products. RLS filters visibility:
    - customers see only active products
    - staff see all products in their branch
    - admins see everything
    """
    conditions, params = [], []

    if branch_id:
        params.append(branch_id)
        conditions.append(f"branch_id = ${len(params)}::uuid")

    if category:
        params.append(category)
        conditions.append(f"category ILIKE ${len(params)}")

    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
    params += [limit, offset]

    async with rls_conn(**current_user) as conn:
        rows = await conn.fetch(
            f"""
            SELECT * FROM products {where}
            ORDER BY name
            LIMIT ${len(params)-1} OFFSET ${len(params)}
            """,
            *params,
        )
    return [ProductResponse.model_validate(dict(r)) for r in rows]


@router.get("/{product_id}", response_model=ProductResponse)
async def get_product(
    product_id: str,
    current_user: dict = Depends(get_current_user),
):
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            "SELECT * FROM products WHERE id = $1::uuid", product_id
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found")
    return ProductResponse.model_validate(dict(row))


@router.post("/", response_model=ProductResponse, status_code=status.HTTP_201_CREATED)
async def create_product(
    body: ProductCreate,
    current_user: dict = Depends(_admin),
):
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO products (branch_id, name, description, sku, price, stock_qty, category)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            RETURNING *
            """,
            body.branch_id, body.name, body.description,
            body.sku, body.price, body.stock_qty, body.category,
        )
    return ProductResponse.model_validate(dict(row))


@router.patch("/{product_id}", response_model=ProductResponse)
async def update_product(
    product_id: str,
    body: ProductUpdate,
    current_user: dict = Depends(_admin),
):
    updates = body.model_dump(exclude_none=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No fields to update",
        )
    set_clause = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(updates))
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            f"UPDATE products SET {set_clause} WHERE id = $1::uuid RETURNING *",
            product_id, *updates.values(),
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found")
    return ProductResponse.model_validate(dict(row))


@router.delete("/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_product(
    product_id: str,
    current_user: dict = Depends(_admin),
):
    async with rls_conn(**current_user) as conn:
        result = await conn.execute(
            "DELETE FROM products WHERE id = $1::uuid", product_id
        )
    if result == "DELETE 0":
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found")
