# app/mine/services/mine_service.py
from __future__ import annotations
from typing import Any, Dict, Optional
from sqlalchemy.orm import Session
from app.extensions import db
from app.mine.repository.mine_repository import SQLAlchemyMineRepository, MineFilter, MineSort
from app.lib.repository.decorators import transactional

class MineService:
    def __init__(self, session: Optional[Session] = None) -> None:
        self.session = session or db.session
        self.repo = SQLAlchemyMineRepository(self.session)

    def list_mines(self, *, page:int=1, per_page:int=20, country:Optional[str]=None,
                   search_query:Optional[str]=None, include_deleted:bool=False,
                   sort_by:str="id", sort_direction:str="asc", include_products:bool=False) -> Dict[str, Any]:
        flt = MineFilter(country=country, q=search_query, include_deleted=include_deleted)
        sort = MineSort(field=sort_by, direction=sort_direction)
        page_obj = self.repo.list(flt, sort=sort, page=page, per_page=per_page, with_products=include_products)
        return {
            "success": True,
            "message": "OK",
            "data": [m.to_dict(include_products=include_products) for m in page_obj.items],
            "metadata": {"total": page_obj.total, "page": page_obj.page, "per_page": page_obj.per_page, "pages": page_obj.pages},
            "errors": [],
        }

    def get_mine(self, mine_id:int, *, include_products:bool=False) -> Dict[str, Any]:
        mine = self.repo.get(mine_id, with_products=include_products)
        if not mine:
            return {"success": False, "message": "Mine not found", "errors": [], "data": None}
        return {"success": True, "message": "OK", "data": mine.to_dict(include_products=include_products), "errors": []}

    @transactional
    def create_mine(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        entity = self.repo.create(payload)
        return {"success": True, "message": "Created", "data": entity.to_dict(), "errors": []}

    @transactional
    def update_mine(self, mine_id:int, payload: Dict[str, Any]) -> Dict[str, Any]:
        entity = self.repo.update_fields(mine_id, payload)
        return {"success": True, "message": "Updated", "data": entity.to_dict(), "errors": []}

    @transactional
    def delete_mine(self, mine_id:int, *, soft:bool=True) -> Dict[str, Any]:
        self.repo.delete(mine_id, soft=soft)
        return {"success": True, "message": "Deleted", "data": None, "errors": []}

    @transactional
    def restore_mine(self, mine_id:int) -> Dict[str, Any]:
        self.repo.restore(mine_id)
        return {"success": True, "message": "Restored", "data": None, "errors": []}
