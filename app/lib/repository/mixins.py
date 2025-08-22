from __future__ import annotations
from typing import Any, Dict, Optional
from sqlalchemy import Select, and_




class FilterableRepositoryMixin:
    """Fornece helper para filtros comuns (ilike, ranges, etc.).
    Usar em conjunto com BaseRepository (herança múltipla).
    """


    def _apply_text_search(self, stmt: Select, *, field: str, q: Optional[str]) -> Select:
        if not q:
            return stmt
        if hasattr(self.model_class, field):
            col = getattr(self.model_class, field)
            stmt = stmt.where(col.ilike(f"%{q}%"))
        return stmt


    def _apply_range(self, stmt: Select, *, field: str, start: Any = None, end: Any = None) -> Select:
        if not hasattr(self.model_class, field):
            return stmt
        col = getattr(self.model_class, field)
        conds = []
        if start is not None:
            conds.append(col >= start)
        if end is not None:
            conds.append(col <= end)
        if conds:
            stmt = stmt.where(and_(*conds))
        return stmt
