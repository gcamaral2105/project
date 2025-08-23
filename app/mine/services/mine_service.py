from __future__ import annotations

from typing import Any, Dict, Optional

from sqlalchemy.orm import Session

from app.extensions import db
from app.lib.repository.decorators import transactional
from app.lib.services.base import BaseService
from app.mine.repository.mine_repository import (
    SQLAlchemyMineRepository,
    MineFilter,
    MineSort,
)


class MineService(BaseService):
    """
    Service orchestrating Mine operations with validation, envelopes, and transactions.
    """

    def __init__(self, session: Optional[Session] = None) -> None:
        super().__init__()
        self.session = session or db.session
        self.repository = SQLAlchemyMineRepository(self.session)

    # ------------------- read ops -------------------
    def list_mines(
        self,
        *,
        page: int = 1,
        per_page: int = 20,
        country: Optional[str] = None,
        search_query: Optional[str] = None,
        include_deleted: bool = False,
        sort_by: str = "id",
        sort_direction: str = "asc",
        include_products: bool = False,
    ) -> Dict[str, Any]:
        flt = MineFilter(country=country, q=search_query, include_deleted=include_deleted)
        sort = MineSort(field=sort_by, direction=sort_direction)
        page_obj = self.repository.list(
            flt, sort=sort, page=page, per_page=per_page, with_products=include_products
        )
        return self.ok(
            "OK",
            data=[m.to_dict(include_products=include_products) for m in page_obj.items],
            metadata={
                "total": page_obj.total,
                "page": page_obj.page,
                "per_page": page_obj.per_page,
                "pages": page_obj.pages,
            },
        )

    def get_mine(self, mine_id: int, *, include_products: bool = False) -> Dict[str, Any]:
        mine = self.repository.get(mine_id, with_products=include_products)
        if not mine:
            return self.error("Mine not found", error_code="NOT_FOUND")
        return self.ok("OK", data=mine.to_dict(include_products=include_products))

    # ------------------- write ops -------------------
    @transactional
    def create_mine(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        # minimal validation
        errs = self.validate_required(payload, ["name"])
        if errs:
            return self.validation_error(errs)

        entity = self.repository.create(payload)
        return self.ok("Created", data=entity.to_dict())

    @transactional
    def update_mine(self, mine_id: int, payload: Dict[str, Any]) -> Dict[str, Any]:
        entity = self.repository.update_fields(mine_id, payload)
        return self.ok("Updated", data=entity.to_dict())

    @transactional
    def delete_mine(self, mine_id: int, *, soft: bool = True) -> Dict[str, Any]:
        self.repository.delete(mine_id, soft=soft)
        return self.ok("Deleted")

    @transactional
    def restore_mine(self, mine_id: int) -> Dict[str, Any]:
        self.repository.restore(mine_id)
        return self.ok("Restored")
