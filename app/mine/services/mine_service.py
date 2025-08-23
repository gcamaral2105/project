from __future__ import annotations

from typing import Any, Dict, List, Optional

from app.extensions import db
from app.lib.services.base import BaseService
from app.lib.repository.decorators import transactional
from app.mine.repository.mine_repository import SQLAlchemyMineRepository


class MineService(BaseService):
    """
    Mine service with nested products support:
    - create_mine(..., products=[...])
    - update_mine(..., products=[...], delete_missing_products=bool)
    """

    def __init__(self, repository: Optional[SQLAlchemyMineRepository] = None) -> None:
        super().__init__(repository or SQLAlchemyMineRepository(db.session))

    # ------------ queries ------------
    def list_mines(self, page: int = 1, per_page: int = 20, **filters):
        return self.paginate(page=page, per_page=per_page, **filters)

    def get_mine(self, mine_id: int):
        def _op():
            return self.repository.get_by_id(mine_id)
        result = self.safe_repository_operation("read", _op)
        if isinstance(result, dict) and result.get("success") is False:
            return result
        if result is None:
            return self.error("Mine not found", error_code="NOT_FOUND")
        return self.ok("Mine retrieved", data=result.to_dict(deep=False))

    # ------------ create ------------
    @transactional
    def create_mine(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        required = ["name", "code", "country"]
        constraints = {
            "name": {"type": str, "min_length": 2, "max_length": 120},
            "code": {"type": str, "min_length": 1, "max_length": 50},
            "country": {"type": str, "min_length": 2, "max_length": 100},
        }
        errors = self.run_validations(payload, required=required, constraints=constraints)
        if errors:
            return self.validation_error(errors)

        mine_data = {
            "name": self.sanitize(payload.get("name")),
            "code": self.sanitize(payload.get("code")),
            "country": self.sanitize(payload.get("country")),
            "description": self.sanitize(payload.get("description")),
        }

        raw_products = payload.get("products") or []
        products: List[Dict[str, Any]] = []
        for p in raw_products:
            # Accept minimal set for create
            pname = self.sanitize(p.get("name"))
            if not pname:
                continue  # ignore invalid product rows silently; you can collect errors if you prefer
            products.append(
                {
                    "name": pname,
                    "code": self.sanitize(p.get("code")),
                    "description": self.sanitize(p.get("description")),
                }
            )

        def _op():
            return self.repository.create_with_products(mine_data, products or None)

        result = self.safe_repository_operation("create", _op)
        if isinstance(result, dict) and result.get("success") is False:
            return result
        return self.ok("Mine created", data=result.to_dict(deep=True))

    # ------------ update + product sync ------------
    @transactional
    def update_mine(self, mine_id: int, payload: Dict[str, Any]) -> Dict[str, Any]:
        constraints = {
            "name": {"type": str, "min_length": 2, "max_length": 120},
            "code": {"type": str, "min_length": 1, "max_length": 50},
            "country": {"type": str, "min_length": 2, "max_length": 100},
        }
        errors = self.run_validations(payload, constraints=constraints)
        if errors:
            return self.validation_error(errors)

        delete_missing_products = bool(payload.get("delete_missing_products", False))
        raw_products = payload.get("products", None)  # if omitted, we don't touch products

        def _op():
            mine = self.repository.get_by_id(mine_id)
            if mine is None:
                raise ValueError("Mine not found")

            # update mine fields
            for f in ["name", "code", "country", "description"]:
                if f in payload:
                    setattr(mine, f, self.sanitize(payload[f]))

            # sync products if requested
            sync_result = None
            if isinstance(raw_products, list):
                normalized: List[Dict[str, Any]] = []
                for p in raw_products:
                    item: Dict[str, Any] = {}
                    if "id" in p:
                        item["id"] = p["id"]
                    if "code" in p:
                        item["code"] = self.sanitize(p.get("code"))
                    # optional action: "delete"
                    if "_action" in p:
                        item["_action"] = str(p.get("_action")).lower().strip()
                    # updatable fields
                    for f in ("name", "description"):
                        if f in p:
                            item[f] = self.sanitize(p.get(f))
                    normalized.append(item)

                sync_result = self.repository.sync_products_for_mine(
                    mine,
                    normalized,
                    delete_missing=delete_missing_products,
                )

            db.session.flush()
            return mine, sync_result

        result = self.safe_repository_operation("update", _op)
        if isinstance(result, dict) and result.get("success") is False:
            return result

        mine, sync = result
        return self.ok(
            "Mine updated",
            data={
                "mine": mine.to_dict(deep=True),
                "products_sync": sync,
            },
        )

    # ------------ delete / restore ------------
    @transactional
    def delete_mine(self, mine_id: int) -> Dict[str, Any]:
        def _op():
            mine = self.repository.get_by_id(mine_id)
            if mine is None:
                raise ValueError("Mine not found")
            self.repository.soft_delete(mine)
            return True

        result = self.safe_repository_operation("delete", _op)
        if isinstance(result, dict) and result.get("success") is False:
            return result
        return self.ok("Mine deleted", data={"id": mine_id})

    @transactional
    def restore_mine(self, mine_id: int) -> Dict[str, Any]:
        def _op():
            mine = self.repository.get_by_id(mine_id, include_deleted=True)
            if mine is None:
                raise ValueError("Mine not found")
            self.repository.restore(mine)
            return mine

        result = self.safe_repository_operation("create", _op)
        if isinstance(result, dict) and result.get("success") is False:
            return result
        return self.ok("Mine restored", data=result.to_dict(deep=False))

