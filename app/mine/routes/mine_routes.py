from __future__ import annotations

from typing import Any, Dict, Tuple

from flask import Blueprint, jsonify, request

from app.mine.services.mine_service import MineService

mine_bp = Blueprint("mines", __name__, url_prefix="/api/mines")


# ----------------- small request helpers (local) -----------------
def _bool(arg_val: str | None, default: bool = False) -> bool:
    if arg_val is None:
        return default
    return arg_val.lower() in {"1", "true", "t", "yes", "y"}

def _pagination() -> Tuple[int, int]:
    try:
        page = int(request.args.get("page", 1))
    except Exception:  # noqa: BLE001
        page = 1
    try:
        per_page = int(request.args.get("per_page", 20))
    except Exception:  # noqa: BLE001
        per_page = 20
    return page, per_page

def _filters() -> Dict[str, Any]:
    return {
        "country": request.args.get("country"),
        "search_query": request.args.get("q") or request.args.get("search_query"),
        "include_deleted": _bool(request.args.get("include_deleted"), default=False),
        "sort_by": request.args.get("sort_by", "id"),
        "sort_direction": request.args.get("sort_direction", "asc"),
        "include_products": _bool(request.args.get("include_products"), default=False),
    }

def _json() -> Dict[str, Any]:
    data = request.get_json(silent=True) or {}
    if not isinstance(data, dict):
        return {}
    return data

def _svc() -> MineService:
    return MineService()


# ----------------- endpoints -----------------
@mine_bp.get("")
def list_mines():
    page, per_page = _pagination()
    res = _svc().list_mines(page=page, per_page=per_page, **_filters())
    return jsonify(res), 200


@mine_bp.get("/<int:mine_id>")
def get_mine(mine_id: int):
    res = _svc().get_mine(mine_id, include_products=_bool(request.args.get("include_products")))
    return jsonify(res), (200 if res.get("success") else 404)


@mine_bp.post("")
def create_mine():
    res = _svc().create_mine(_json())
    code = 201 if res.get("success") else 400
    return jsonify(res), code


@mine_bp.put("/<int:mine_id>")
@mine_bp.patch("/<int:mine_id>")
def update_mine(mine_id: int):
    res = _svc().update_mine(mine_id, _json())
    code = 200 if res.get("success") else 400
    return jsonify(res), code


@mine_bp.delete("/<int:mine_id>")
def delete_mine(mine_id: int):
    soft = _bool(request.args.get("soft"), default=True)
    res = _svc().delete_mine(mine_id, soft=soft)
    code = 200 if res.get("success") else 400
    return jsonify(res), code


@mine_bp.post("/<int:mine_id>/restore")
def restore_mine(mine_id: int):
    res = _svc().restore_mine(mine_id)
    code = 200 if res.get("success") else 400
    return jsonify(res), code

