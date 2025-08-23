from __future__ import annotations

from http import HTTPStatus
from typing import Any, Dict

from flask import Blueprint, current_app, jsonify, request

from app.auth.utils.jwt import encode_jwt

auth_bp = Blueprint("auth_bp", __name__, url_prefix="/api/auth")


@auth_bp.post("/login")
def login():
    """
    DEV login issuing a JWT.
    Replace with real user lookup (DB) when your User model is ready.
    Body: { "username": str, "password": str }
    """
    if not request.is_json:
        return jsonify({"success": False, "message": "JSON required"}), HTTPStatus.BAD_REQUEST

    data: Dict[str, Any] = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""

    demo_user = current_app.config.get("AUTH_DEMO_USERNAME", "admin")
    demo_pass = current_app.config.get("AUTH_DEMO_PASSWORD", "admin")

    if not username or not password:
        return jsonify({"success": False, "message": "Username and password are required"}), HTTPStatus.BAD_REQUEST

    # DEV ONLY: accept the configured demo credentials
    if username != demo_user or password != demo_pass:
        return jsonify({"success": False, "message": "Invalid credentials"}), HTTPStatus.UNAUTHORIZED

    token = encode_jwt(
        {"sub": username, "roles": ["user"]},
        secret=current_app.config["JWT_SECRET_KEY"],
        algorithm=current_app.config.get("JWT_ALGORITHM", "HS256"),
        expires_minutes=current_app.config.get("JWT_EXPIRES_MINUTES", 60),
    )

    return jsonify(
        {
            "success": True,
            "message": "Login successful",
            "data": {"access_token": token, "token_type": "Bearer"},
        }
    ), HTTPStatus.OK
