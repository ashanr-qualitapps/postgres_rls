from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, ConfigDict, EmailStr, field_validator

_CFG = ConfigDict(from_attributes=True)

# ════════════════════════════════════════════════════════════════════════════
# Auth
# ════════════════════════════════════════════════════════════════════════════

class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str
    full_name: str
    phone: Optional[str] = None
    branch_id: Optional[uuid.UUID] = None

    @field_validator("password")
    @classmethod
    def _pw_length(cls, v: str) -> str:
        if len(v) < 8:
            raise ValueError("Password must be at least 8 characters")
        return v


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


# ════════════════════════════════════════════════════════════════════════════
# Branches
# ════════════════════════════════════════════════════════════════════════════

class BranchCreate(BaseModel):
    name: str
    address: Optional[str] = None
    phone: Optional[str] = None
    timezone: str = "UTC"


class BranchUpdate(BaseModel):
    name: Optional[str] = None
    address: Optional[str] = None
    phone: Optional[str] = None
    timezone: Optional[str] = None
    is_active: Optional[bool] = None


class BranchResponse(BaseModel):
    model_config = _CFG

    id: uuid.UUID
    name: str
    address: Optional[str] = None
    phone: Optional[str] = None
    timezone: str
    is_active: bool
    created_at: datetime
    updated_at: datetime


# ════════════════════════════════════════════════════════════════════════════
# Users
# ════════════════════════════════════════════════════════════════════════════

class UserUpdate(BaseModel):
    full_name: Optional[str] = None
    phone: Optional[str] = None


class AdminUserUpdate(UserUpdate):
    role: Optional[str] = None
    branch_id: Optional[uuid.UUID] = None
    is_active: Optional[bool] = None

    @field_validator("role")
    @classmethod
    def _valid_role(cls, v: Optional[str]) -> Optional[str]:
        if v and v not in {"customer", "staff", "admin"}:
            raise ValueError("role must be customer, staff, or admin")
        return v


class UserResponse(BaseModel):
    model_config = _CFG

    id: uuid.UUID
    branch_id: Optional[uuid.UUID] = None
    email: str
    full_name: str
    phone: Optional[str] = None
    role: str
    is_active: bool
    created_at: datetime


# ════════════════════════════════════════════════════════════════════════════
# Services
# ════════════════════════════════════════════════════════════════════════════

class ServiceCreate(BaseModel):
    branch_id: Optional[uuid.UUID] = None
    name: str
    description: Optional[str] = None
    duration_min: int = 60
    price: Decimal
    category: Optional[str] = None


class ServiceUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    duration_min: Optional[int] = None
    price: Optional[Decimal] = None
    category: Optional[str] = None
    is_active: Optional[bool] = None


class ServiceResponse(BaseModel):
    model_config = _CFG

    id: uuid.UUID
    branch_id: Optional[uuid.UUID] = None
    name: str
    description: Optional[str] = None
    duration_min: int
    price: Decimal
    category: Optional[str] = None
    is_active: bool
    created_at: datetime
    updated_at: datetime


# ════════════════════════════════════════════════════════════════════════════
# Appointments
# ════════════════════════════════════════════════════════════════════════════

_APPT_STATUSES = {"pending", "confirmed", "completed", "cancelled", "no_show"}


class AppointmentCreate(BaseModel):
    service_id: uuid.UUID
    branch_id: uuid.UUID
    scheduled_at: datetime
    staff_id: Optional[uuid.UUID] = None
    notes: Optional[str] = None


class AppointmentUpdate(BaseModel):
    status: Optional[str] = None
    notes: Optional[str] = None
    scheduled_at: Optional[datetime] = None
    staff_id: Optional[uuid.UUID] = None

    @field_validator("status")
    @classmethod
    def _valid_status(cls, v: Optional[str]) -> Optional[str]:
        if v and v not in _APPT_STATUSES:
            raise ValueError(f"status must be one of {_APPT_STATUSES}")
        return v


class AppointmentResponse(BaseModel):
    model_config = _CFG

    id: uuid.UUID
    user_id: uuid.UUID
    staff_id: Optional[uuid.UUID] = None
    service_id: uuid.UUID
    branch_id: uuid.UUID
    scheduled_at: datetime
    duration_min: int
    status: str
    notes: Optional[str] = None
    created_at: datetime
    updated_at: datetime


# ════════════════════════════════════════════════════════════════════════════
# Products
# ════════════════════════════════════════════════════════════════════════════

class ProductCreate(BaseModel):
    branch_id: Optional[uuid.UUID] = None
    name: str
    description: Optional[str] = None
    sku: Optional[str] = None
    price: Decimal
    stock_qty: int = 0
    category: Optional[str] = None


class ProductUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    sku: Optional[str] = None
    price: Optional[Decimal] = None
    stock_qty: Optional[int] = None
    category: Optional[str] = None
    is_active: Optional[bool] = None


class ProductResponse(BaseModel):
    model_config = _CFG

    id: uuid.UUID
    branch_id: Optional[uuid.UUID] = None
    name: str
    description: Optional[str] = None
    sku: Optional[str] = None
    price: Decimal
    stock_qty: int
    category: Optional[str] = None
    is_active: bool
    created_at: datetime
    updated_at: datetime


# ════════════════════════════════════════════════════════════════════════════
# Orders
# ════════════════════════════════════════════════════════════════════════════

_ORDER_STATUSES = {"pending", "paid", "shipped", "delivered", "cancelled", "refunded"}


class OrderItemCreate(BaseModel):
    product_id: uuid.UUID
    quantity: int = 1


class OrderCreate(BaseModel):
    branch_id: uuid.UUID
    items: list[OrderItemCreate]
    notes: Optional[str] = None


class OrderUpdate(BaseModel):
    status: Optional[str] = None
    notes: Optional[str] = None

    @field_validator("status")
    @classmethod
    def _valid_status(cls, v: Optional[str]) -> Optional[str]:
        if v and v not in _ORDER_STATUSES:
            raise ValueError(f"status must be one of {_ORDER_STATUSES}")
        return v


class OrderItemResponse(BaseModel):
    model_config = _CFG

    id: uuid.UUID
    product_id: uuid.UUID
    quantity: int
    unit_price: Decimal


class OrderResponse(BaseModel):
    model_config = _CFG

    id: uuid.UUID
    user_id: uuid.UUID
    branch_id: uuid.UUID
    total_amount: Decimal
    status: str
    notes: Optional[str] = None
    items: list[OrderItemResponse] = []
    created_at: datetime
    updated_at: datetime
