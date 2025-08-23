from __future__ import annotations

from typing import Any, Dict, List, Optional

from app.extensions import db
from app.lib.services.base import BaseService
from app.lib.repository.decorators import transactional
from app.mine.repository.mine_repository import SQLAlchemyMineRepository


class MineService(BaseService):
    """
    Service layer for Mine. Uses BaseService helpers:
    - run_validations(...)
    - safe_repository_operation(...)
    - ok/error/validation_error envelopes
    - @transactional for one-commit-per-call policy
    """

    def __init__(self, repository: Optional[SQLAlchemyMineRepository] = None) -> None:
        super().__init__(repository or SQLAlchemyMineRepository(db.session))

    # ------------ queries ------------
    def list_mines(self, page: int = 1, per_page: int = 20, **filters):
        # keep cache-friendly paginate from BaseService
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
        """
        Expected payload at minimum:
        { "name": str, "code": str, "country": str, ... }

        Optionally, you may pass "products": [{name, code?, description?}, ...]
        to create products in a single transaction (if your repo supports it).
        """
        required = ["name", "code", "country"]
        constraints = {
            "name": {"type": str, "min_length": 2, "max_length": 120},
            "code": {"type": str, "min_length": 1, "max_length": 50},
            "country": {"type": str, "min_length": 2, "max_length": 100},
        }
        errors = self.run_validations(payload, required=required, constraints=constraints)
        if errors:
            return self.validation_error(errors)

        clean = {
            "name": self.sanitize(payload.get("name")),
            "code": self.sanitize(payload.get("code")),
            "country": self.sanitize(payload.get("country")),
            "description": self.sanitize(payload.get("description")),
        }
        products = payload.get("products") or []

        def _op():
            # If your repository already provides a convenience method to create
            # a mine and its products, you can call it here. Otherwise, create
            # the mine, then add products and flush.
            mine = self.repository.create(clean)
            # Optionally handle nested product creation (if desired)
            if products and hasattr(self.repository, "create_products_for_mine"):
                self.repository.create_products_for_mine(mine, products)
            db.session.flush()
            return mine

        result = self.safe_repository_operation("create", _op)
        if isinstance(result, dict) and result.get("success") is False:
            return result
        return self.ok("Mine created", data=result.to_dict(deep=False))

    # ------------ update ------------
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

        def _op():
            mine = self.repository.get_by_id(mine_id)
            if mine is None:
                raise ValueError("Mine not found")
            for f in ["name", "code", "country", "description"]:
                if f in payload:
                    setattr(mine, f, self.sanitize(payload[f]))
            db.session.flush()
            return mine

        result = self.safe_repository_operation("update", _op)
        if isinstance(result, dict) and result.get("success") is False:
            return result
        return self.ok("Mine updated", data=result.to_dict(deep=False))

    # ------------ delete (soft) ------------
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

    # ------------ restore ------------
    @transactional
    def restore_mine(self, mine_id: int) -> Dict[str, Any]:
        def _op():
            mine = self.repository.get_by_id(mine_id, include_deleted=True)
            if mine is None:
                raise ValueError("Mine not found")
            self.repository.restore(mine)
            return mine

        result = self.safe_repository_operation("create", _op)  # treat restore as create-ish
        if isinstance(result, dict) and result.get("success") is False:
            return result
        return self.ok("Mine restored", data=result.to_dict(deep=False))

