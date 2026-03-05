from fastapi import APIRouter, HTTPException, status

from app.database import raw_conn
from app.auth import create_access_token
from app.models.schemas import (
    LoginRequest,
    RegisterRequest,
    TokenResponse,
    UserResponse,
)

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/login", response_model=TokenResponse)
async def login(body: LoginRequest):
    """
    Exchange email + password for a JWT Bearer token.
    Uses the SECURITY DEFINER authenticate_user() DB function so credentials
    are verified inside PostgreSQL with bcrypt – the plaintext password never
    leaves this layer.
    """
    async with raw_conn() as conn:
        rows = await conn.fetch(
            "SELECT * FROM authenticate_user($1, $2)",
            body.email,
            body.password,
        )

    if not rows:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )

    user = dict(rows[0])
    token = create_access_token(
        user_id=str(user["id"]),
        role=user["role"],
        branch_id=str(user["branch_id"]) if user["branch_id"] else None,
    )
    return TokenResponse(access_token=token)


@router.post(
    "/register",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
)
async def register(body: RegisterRequest):
    """
    Create a new customer account (role = 'customer').
    Uses the SECURITY DEFINER register_user() DB function so the bcrypt hash
    is computed inside PostgreSQL and RLS INSERT restrictions are safely bypassed.
    """
    async with raw_conn() as conn:
        try:
            rows = await conn.fetch(
                "SELECT * FROM register_user($1, $2, $3, $4, $5)",
                body.email,
                body.password,
                body.full_name,
                body.phone,
                body.branch_id,
            )
        except Exception as exc:
            if "EmailAlreadyRegistered" in str(exc):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Email already registered",
                )
            raise

    return UserResponse.model_validate(dict(rows[0]))
