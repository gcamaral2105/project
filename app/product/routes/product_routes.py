from __future__ import annotations

from http import HTTPStatus
from typing import Any, Dict, Tuple

from flask import Blueprint, jsonify, request

from app.product.services.product_service import ProductService

product_bp = Blueprint("product_bp", __name__, url_prefix="/api/products")
service = ProductService()


# --------------------------- helpers --------------------------- #
def _response(envelope: Dict[str, Any], *, success_code=HTTPStatus.OK) -> Tuple[Any, int]:
    """
    Map BaseService envelopes to proper HTTP status codes.
    - success=True  -> 2xx (default 200 or provided)
    - success=False -> choose 4xx/5xx based on error_code / message
    """
    if envelope.get("success"):
        return jsonify(envelope), int(success_code)

    code = str(envelope.get("error_code") or "").upper()
    msg = (envelope.get("message") or "").lower()

    # Common mappings
    if code in {"VALIDATION_ERROR"}:
        status = HTTPStatus.BAD_REQUEST
    elif code in {"NOT_FOUND"} or "not found" in msg:
        status = HTTPStatus.NOT_FOUND
    elif code.endswith("_ERROR"):
        # Operation-level failures (create/update/delete/read)
        status = HTTPStatus.BAD_REQUEST
    else:
        status = HTTPStatus.INTERNAL_SERVER_ERROR

    return jsonify(envelope), int(status)


def _json_body() -> Dict[str, Any]:
    if not request.is_json:
        return {}
    data = request.get_json(silent=True) or {}
    if not isinstance(data, dict):
        return {}
    return data


# --------------------------- routes --------------------------- #
@product_bp.get("")
def list_products():
    """
    GET /api/products
    Query params:
      - page, per_page
      - mine_id, name, code
      - q (free text), sort_by, sort_dir, include_deleted
    """
    page = int(request.args.get("page", 1))
    per_page = int(request.args.get("per_page", 20))

    filters: Dict[str, Any] = {}
    if "mine_id" in request.args:
        try:
            filters["mine_id"] = int(request.args["mine_id"])
        except ValueError:
            pass
    if "name" in request.args:
        filters["name"] = request.args["name"]
    if "code" in request.args:
        filters["code"] = request.args["code"]
    if "q" in request.args:
        filters["q"] = request.args["q"]
    if "sort_by" in request.args:
        filters["sort_by"] = request.args["sort_by"]
    if "sort_dir" in request.args:
        filters["sort_dir"] = request.args["sort_dir"]
    if "include_deleted" in request.args:
        filters["include_deleted"] = request.args.get("include_deleted", "false").lower() in {"1", "true", "yes"}

    # The repository/service already shapes a pagination dict (items/total/etc.)
    data = service.list_products(page=page, per_page=per_page, **filters)
    # list_products returns the raw pagination data (not an envelope); wrap it:
    envelope = service.ok("Products listed", data=data)
    return _response(envelope)


@product_bp.get("/<int:product_id>")
def get_product(product_id: int):
    """
    GET /api/products/<id>
    """
    envelope = service.get_product(product_id)
    return _response(envelope)


@product_bp.post("")
def create_product():
    """
    POST /api/products
    Body (JSON):
      { "name": str, "mine_id": int, "code": str?, "description": str? }
    """
    payload = _json_body()
    if not payload:
        return _response(service.validation_error(["Request body must be a JSON object"]))
    envelope = service.create_product(payload)
    success = HTTPStatus.CREATED if envelope.get("success") else HTTPStatus.BAD_REQUEST
    return _response(envelope, success_code=success)


@product_bp.put("/<int:product_id>")
@product_bp.patch("/<int:product_id>")
def update_product(product_id: int):
    """
    PUT/PATCH /api/products/<id>
    Body: partial or full fields (name, code, description, mine_id)
    """
    payload = _json_body()
    if not payload:
        return _response(service.validation_error(["Request body must be a JSON object"]))
    envelope = service.update_product(product_id, payload)
    return _response(envelope)


@product_bp.delete("/<int:product_id>")
def delete_product(product_id: int):
    """
    DELETE /api/products/<id>  (soft delete)
    """
    envelope = service.delete_product(product_id)
    # 200 OK with envelope (you could also return 204 with no body if you prefer)
    return _response(envelope)


@product_bp.post("/<int:product_id>/restore")
def restore_product(product_id: int):
    """
    POST /api/products/<id>/restore
    """
    envelope = service.restore_product(product_id)
    return _response(envelope)

