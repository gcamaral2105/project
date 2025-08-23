from __future__ import annotations
from typing import Any, Dict

from flask import Blueprint, request, jsonify
from sqlalchemy.exc import SQLAlchemyError

from app.product.services.product_service import ProductService

bp = Blueprint("products", __name__, url_prefix="/api/products")


def _svc() -> ProductService:
    return ProductService()


def _serialize(obj) -> Dict[str, Any]:
    if hasattr(obj, "to_dict"):
        return obj.to_dict()
    return {"id": getattr(obj, "id", None), "name": getattr(obj, "name", None)}


@bp.get("")
def list_products():
    q = request.args.get("q")
    page = int(request.args.get("page", 1))
    per_page = int(request.args.get("per_page", 20))
    order_by = request.args.get("order_by")
    order_desc = request.args.get("order_desc", "false").lower() in ("1", "true", "yes")

    items, total = _svc().list(q, page, per_page, order_by, order_desc)
    return jsonify({
        "items": [_serialize(i) for i in items],
        "total": total,
        "page": page,
        "per_page": per_page,
    })


@bp.get("/deleted")
def list_deleted_products():
    items = _svc().list_deleted()
    return jsonify({"items": [_serialize(i) for i in items]})


@bp.post("")
def create_product():
    try:
        payload = request.get_json(silent=True) or {}
        obj = _svc().create(payload)
        return jsonify(_serialize(obj)), 201
    except (ValueError, LookupError) as e:
        return jsonify({"error": str(e)}), 400
    except SQLAlchemyError as e:
        return jsonify({"error": "Database error", "detail": str(e)}), 500


@bp.get("/<int:product_id>")
def get_product(product_id: int):
    obj = _svc().get(product_id)
    if not obj:
        return jsonify({"error": "Not found"}), 404
    return jsonify(_serialize(obj))


@bp.put("/<int:product_id>")
@bp.patch("/<int:product_id>")
def update_product(product_id: int):
    try:
        payload = request.get_json(silent=True) or {}
        obj = _svc().update(product_id, payload)
        return jsonify(_serialize(obj))
    except (ValueError, LookupError) as e:
        return jsonify({"error": str(e)}), 400
    except SQLAlchemyError as e:
        return jsonify({"error": "Database error", "detail": str(e)}), 500


@bp.delete("/<int:product_id>")
def delete_product(product_id: int):
    try:
        _svc().delete(product_id)
        return jsonify({"status": "deleted"}), 200
    except LookupError as e:
        return jsonify({"error": str(e)}), 404
    except SQLAlchemyError as e:
        return jsonify({"error": "Database error", "detail": str(e)}), 500


@bp.post("/<int:product_id>/restore")
def restore_product(product_id: int):
    try:
        _svc().restore(product_id)
        return jsonify({"status": "restored"}), 200
    except LookupError as e:
        return jsonify({"error": str(e)}), 404
    except SQLAlchemyError as e:
        return jsonify({"error": "Database error", "detail": str(e)}), 500
