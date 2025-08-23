from __future__ import annotations

import logging
import os

from flask import Flask, jsonify
from flask_cors import CORS

from app.extensions import db, migrate
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
    app.register_blueprint(product_bp)
    app.register_blueprint(mine_bp)
    # TODO: register other BPs when available (auth, production, partner, etc.)

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



