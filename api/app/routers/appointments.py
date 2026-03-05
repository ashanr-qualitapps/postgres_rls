import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.database import rls_conn
from app.dependencies import get_current_user, require_role
from app.models.schemas import (
    AppointmentCreate,
    AppointmentUpdate,
    AppointmentResponse,
)

router = APIRouter(prefix="/appointments", tags=["appointments"])

_staff_or_admin = require_role("staff", "admin")


@router.get("/", response_model=list[AppointmentResponse])
async def list_appointments(
    branch_id: str | None = Query(None),
    status_filter: str | None = Query(None, alias="status"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
):
    """
    List appointments. RLS enforces visibility:
    - customers see only their own appointments
    - staff see all appointments in their branch
    - admins see everything
    """
    conditions, params = [], []

    if branch_id:
        params.append(branch_id)
        conditions.append(f"branch_id = ${len(params)}::uuid")

    if status_filter:
        params.append(status_filter)
        conditions.append(f"status = ${len(params)}")

    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
    params += [limit, offset]

    async with rls_conn(**current_user) as conn:
        rows = await conn.fetch(
            f"""
            SELECT * FROM appointments {where}
            ORDER BY scheduled_at DESC
            LIMIT ${len(params)-1} OFFSET ${len(params)}
            """,
            *params,
        )
    return [AppointmentResponse.model_validate(dict(r)) for r in rows]


@router.get("/{appointment_id}", response_model=AppointmentResponse)
async def get_appointment(
    appointment_id: str,
    current_user: dict = Depends(get_current_user),
):
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            "SELECT * FROM appointments WHERE id = $1::uuid", appointment_id
        )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Appointment not found")
    return AppointmentResponse.model_validate(dict(row))


@router.post("/", response_model=AppointmentResponse, status_code=status.HTTP_201_CREATED)
async def create_appointment(
    body: AppointmentCreate,
    current_user: dict = Depends(get_current_user),
):
    """
    Book an appointment.
    The user_id is always taken from the JWT – customers cannot book for others.
    Staff and admins can supply an explicit user_id via PATCH after creation if needed.
    """
    # Fetch the service duration to store on the appointment
    async with rls_conn(**current_user) as conn:
        svc = await conn.fetchrow(
            "SELECT duration_min FROM services WHERE id = $1::uuid", str(body.service_id)
        )
        if not svc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Service not found")

        row = await conn.fetchrow(
            """
            INSERT INTO appointments
                (user_id, staff_id, service_id, branch_id, scheduled_at, duration_min, notes)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            RETURNING *
            """,
            uuid.UUID(current_user["user_id"]),
            body.staff_id,
            body.service_id,
            body.branch_id,
            body.scheduled_at,
            svc["duration_min"],
            body.notes,
        )
    return AppointmentResponse.model_validate(dict(row))


@router.patch("/{appointment_id}", response_model=AppointmentResponse)
async def update_appointment(
    appointment_id: str,
    body: AppointmentUpdate,
    current_user: dict = Depends(get_current_user),
):
    """
    Update an appointment.
    - Customers can only update their own pending/confirmed appointments.
    - Staff can update any appointment in their branch.
    - Admins have full access.
    RLS enforces these constraints at the database level.
    """
    updates = body.model_dump(exclude_none=True)
    if not updates:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No fields to update",
        )
    set_clause = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(updates))
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            f"UPDATE appointments SET {set_clause} WHERE id = $1::uuid RETURNING *",
            appointment_id, *updates.values(),
        )
    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Appointment not found or you lack permission to update it",
        )
    return AppointmentResponse.model_validate(dict(row))


@router.delete("/{appointment_id}", status_code=status.HTTP_204_NO_CONTENT)
async def cancel_appointment(
    appointment_id: str,
    current_user: dict = Depends(get_current_user),
):
    """Cancel (soft-delete via status) an appointment."""
    async with rls_conn(**current_user) as conn:
        row = await conn.fetchrow(
            """
            UPDATE appointments
               SET status = 'cancelled'
             WHERE id = $1::uuid
               AND status IN ('pending', 'confirmed')
            RETURNING id
            """,
            appointment_id,
        )
    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Appointment not found, already finalised, or you lack permission",
        )
