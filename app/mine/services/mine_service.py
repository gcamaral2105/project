from __future__ import annotations
from typing import Any, Dict, Optional, Tuple

from app.mine.repository.mine_repository import MineRepository
from app.lib.repository.decorators import transactional  # @transactional


class MineService:
    """
    Regras de negócio para cenários de Production (domínio Mine).
    - Métodos de escrita usam @transactional.
    """

    def __init__(self) -> None:
        self.repo = MineRepository()

    # --------------------- Leituras --------------------- #
    def get(self, production_id: int):
        return self.repo.get_by_id(production_id)

    def list(
        self,
        q: Optional[str],
        page: int,
        per_page: int,
        period_start: Optional[str],
        period_end: Optional[str],
        status: Optional[str],
        order_desc: bool,
    ) -> Tuple[list, int]:
        return self.repo.search_paginated(
            q=q,
            page=page,
            per_page=per_page,
            period_start=period_start,
            period_end=period_end,
            status=status,
            order_desc=order_desc,
        )

    def list_active(self) -> list:
        return self.repo.get_active()

    def list_deleted(self) -> list:
        return self.repo.get_deleted()

    # --------------------- Escritas (transacionais) --------------------- #
    @transactional
    def create(self, payload: Dict[str, Any]):
        # Validações mínimas — ajuste conforme seu model Production
        name = (payload.get("scenario_name") or "").strip()
        if not name:
            raise ValueError("scenario_name is required")
        contractual_year = payload.get("contractual_year")
        if contractual_year is None:
            raise ValueError("contractual_year is required")
        return self.repo.create(**payload)

    @transactional
    def update(self, production_id: int, payload: Dict[str, Any]):
        updated = self.repo.update(production_id, **payload)
        if not updated:
            raise LookupError("Production not found")
        return updated

    @transactional
    def delete(self, production_id: int) -> None:
        ok = self.repo.delete(production_id)  # soft-delete
        if not ok:
            raise LookupError("Production not found")

    @transactional
    def restore(self, production_id: int) -> None:
        ok = self.repo.restore(production_id)
        if not ok:
            raise LookupError("Production not found or not deleted")
