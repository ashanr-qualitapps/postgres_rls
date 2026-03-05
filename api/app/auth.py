from datetime import datetime, timedelta, timezone
from typing import Optional

from jose import JWTError, jwt

from app.config import get_settings


def create_access_token(
    user_id: str,
    role: str,
    branch_id: Optional[str],
    expires_delta: Optional[timedelta] = None,
) -> str:
    s = get_settings()
    expire = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=s.JWT_EXPIRE_MINUTES)
    )
    payload = {
        "sub": user_id,
        "role": role,
        "branch_id": branch_id,
        "exp": expire,
    }
    return jwt.encode(payload, s.JWT_SECRET, algorithm=s.JWT_ALGORITHM)


def decode_token(token: str) -> dict:
    s = get_settings()
    try:
        payload = jwt.decode(token, s.JWT_SECRET, algorithms=[s.JWT_ALGORITHM])
    except JWTError as exc:
        raise ValueError("Invalid or expired token") from exc
    if not payload.get("sub"):
        raise ValueError("Token missing subject claim")
    return payload
