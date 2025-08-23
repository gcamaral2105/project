from __future__ import annotations

import logging
import os
from typing import Any, Dict

from flask import Flask, jsonify, g, request
from flask_cors import CORS

from app.extensions import db, migrate
from app.auth.routes.auth_routes import auth_bp
from app.auth.utils.jwt import decode_jwt, get_bearer_token
from app.product.routes.product_routes import product_bp
from app.mine.routes.mine_routes import mine_bp


def create_app(config_object: str | None = None) -> Flask:
    """
    Application Factory.
    Select config class via env var APP_CONFIG (fallback to 'config.Config').
    """
    app = Flask(__name__)

    config_object = config_object or os.getenv("APP_CONFIG", "config.Config")
    app.config.from_object(config_object)

    # ---- extensions ----
    db.init_app(app)
    migrate.init_app(app, db)
    CORS(app, resources={r"/api/*": {"origins": app.config.get("CORS_ORIGINS", "*")}})

    # ---- logging (simple sane defaults) ----
    if not app.debug and not app.testing:
        handler = logging.StreamHandler()
        handler.setLevel(logging.INFO)
        app.logger.addHandler(handler)

    # ---- blueprints ----
    app.register_blueprint(auth_bp)     # /api/auth/*
    app.register_blueprint(product_bp)  # /api/products/*
    app.register_blueprint(mine_bp)     # /api/mines/*

    # ---- JWT guard for /api/* except /api/auth/* ----
    @app.before_request
    def _jwt_guard():
        # Preflight
        if request.method == "OPTIONS":
            return None

        path = request.path or ""
        if not path.startswith("/api/"):
            return None
        if path.startswith("/api/auth/"):
            return None  # login etc.

        token = get_bearer_token(request.headers.get("Authorization"))
        if not token:
            return jsonify({"success": False, "message": "Missing Bearer token"}), 401

        try:
            claims = decode_jwt(
                token,
                secret=app.config["JWT_SECRET_KEY"],
                algorithms=[app.config.get("JWT_ALGORITHM", "HS256")],
            )
            # Make claims available to handlers
            g.jwt = claims
        except Exception as exc:  # noqa: BLE001
            return jsonify({"success": False, "message": "Invalid or expired token", "errors": [str(exc)]}), 401

        return None

    # ---- error handlers (JSON) ----
    @app.errorhandler(400)
    def bad_request(err):
        return jsonify({"success": False, "message": "Bad request", "errors": [str(err)]}), 400

    @app.errorhandler(404)
    def not_found(err):
        return jsonify({"success": False, "message": "Not found", "errors": [str(err)]}), 404

    @app.errorhandler(405)
    def method_not_allowed(err):
        return jsonify({"success": False, "message": "Method not allowed", "errors": [str(err)]}), 405

    @app.errorhandler(500)
    def server_error(err):
        return jsonify({"success": False, "message": "Internal server error", "errors": [str(err)]}), 500

    return app
