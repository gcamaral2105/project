from __future__ import annotations
from typing import Any, Dict, List, Optional, Tuple

from sqlalchemy import func, or_

from app.models.production import Production
from app.lib.repository.base import BaseRepository


class MineRepository(BaseRepository[Production]):
    """
    Repository de Production (domínio Mine) baseado em BaseRepository.
    """

    ENABLE_SOFT_DELETE: bool = True  # respeita deleted_at em Production/BaseModel

    def __init__(self) -> None:
        super().__init__(Production)

    def find_by_criteria(self, criteria: Dict[str, Any]) -> List[Production]:
        return super().find_by_multiple_criteria(criteria, operator="AND")

    def search_paginated(
        self,
        q: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        period_start: Optional[str] = None,
        period_end: Optional[str] = None,
        status: Optional[str] = None,
        order_desc: bool = True,
    ) -> Tuple[List[Production], int]:
        """
        Lista produções com filtros de janela temporal e status.
        Respeita soft-delete.
        """
        query = Production.query
        if hasattr(Production, "deleted_at"):
            query = query.filter(Production.deleted_at.is_(None))

        if q:
            like = f"%{q.strip()}%"
            conds = []
            if hasattr(Production, "scenario_name"):
                conds.append(Production.scenario_name.ilike(like))
            if hasattr(Production, "scenario_description"):
                conds.append(Production.scenario_description.ilike(like))
            if conds:
                query = query.filter(or_(*conds))

        if period_start and hasattr(Production, "start_date_contractual_year"):
            query = query.filter(Production.start_date_contractual_year >= period_start)
        if period_end and hasattr(Production, "end_date_contractual_year"):
            query = query.filter(Production.end_date_contractual_year <= period_end)

        if status and hasattr(Production, "status"):
            query = query.filter(func.lower(Production.status) == func.lower(status))

        # ordenação por data de início quando disponível
        order_col = getattr(Production, "start_date_contractual_year", Production.id)
        query = query.order_by(order_col.desc() if order_desc else order_col.asc())

        total = query.count()
        items = query.offset((page - 1) * per_page).limit(per_page).all()
        return items, total
