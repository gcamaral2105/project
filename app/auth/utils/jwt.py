from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, Optional

import jwt


def encode_jwt(
    claims: Dict[str, Any],
    secret: str,
    algorithm: str = "HS256",
    expires_minutes: int = 60,
) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        **claims,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=expires_minutes)).timestamp()),
    }
    return jwt.encode(payload, secret, algorithm=algorithm)


def decode_jwt(token: str, secret: str, algorithms: Iterable[str]) -> Dict[str, Any]:
    return jwt.decode(token, secret, algorithms=list(algorithms))


def get_bearer_token(auth_header: Optional[str]) -> Optional[str]:
    if not auth_header:
        return None
    parts = auth_header.split()
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1]
    return None
