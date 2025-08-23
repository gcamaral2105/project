from __future__ import annotations

from http import HTTPStatus
from typing import Any, Dict, Tuple

from flask import Blueprint, jsonify, request

from app.mine.services.mine_service import MineService

mine_bp = Blueprint("mine_bp", __name__, url_prefix="/api/mines")
service = MineService()


# --------------------------- helpers --------------------------- #
def _response(envelope: Dict[str, Any], *, success_code=HTTPStatus.OK) -> Tuple[Any, int]:
    """
    Map BaseService envelopes to proper HTTP status codes.
    """
    if envelope.get("success"):
        return jsonify(envelope), int(success_code)

    code = str(envelope.get("error_code") or "").upper()
    msg = (envelope.get("message") or "").lower()

    if code in {"VALIDATION_ERROR"}:
        status = HTTPStatus.BAD_REQUEST
    elif code in {"NOT_FOUND"} or "not found" in msg:
        status = HTTPStatus.NOT_FOUND
    elif code.endswith("_ERROR"):
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
@mine_bp.get("")
def list_mines():
    """
    GET /api/mines
    Query params:
      - page, per_page
      - name, code, country, q (free text)
      - sort_by, sort_dir, include_deleted
    """
    page = int(request.args.get("page", 1))
    per_page = int(request.args.get("per_page", 20))

    filters: Dict[str, Any] = {}
    for f in ["name", "code", "country", "q", "sort_by", "sort_dir"]:
        if f in request.args:
            filters[f] = request.args[f]

    if "include_deleted" in request.args:
        filters["include_deleted"] = request.args.get("include_deleted", "false").lower() in {"1", "true", "yes"}

    data = service.list_mines(page=page, per_page=per_page, **filters)
    envelope = service.ok("Mines listed", data=data)
    return _response(envelope)


@mine_bp.get("/<int:mine_id>")
def get_mine(mine_id: int):
    envelope = service.get_mine(mine_id)
    return _response(envelope)


@mine_bp.post("")
def create_mine():
    """
    POST /api/mines
    Body (JSON):
      { "name": str, "code": str, "country": str, "description"?: str,
        "products"?: [{ "name": str, "code"?: str, "description"?: str }, ...] }
    """
    payload = _json_body()
    if not payload:
        return _response(service.validation_error(["Request body must be a JSON object"]))
    envelope = service.create_mine(payload)
    success = HTTPStatus.CREATED if envelope.get("success") else HTTPStatus.BAD_REQUEST
    return _response(envelope, success_code=success)


@mine_bp.put("/<int:mine_id>")
@mine_bp.patch("/<int:mine_id>")
def update_mine(mine_id: int):
    payload = _json_body()
    if not payload:
        return _response(service.validation_error(["Request body must be a JSON object"]))
    envelope = service.update_mine(mine_id, payload)
    return _response(envelope)


@mine_bp.delete("/<int:mine_id>")
def delete_mine(mine_id: int):
    envelope = service.delete_mine(mine_id)
    return _response(envelope)


@mine_bp.post("/<int:mine_id>/restore")
def restore_mine(mine_id: int):
    envelope = service.restore_mine(mine_id)
    return _response(envelope)
