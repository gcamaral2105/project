from __future__ import annotations
from typing import Any, Dict, List, Optional, Sequence, Tuple

from sqlalchemy import func, or_
from sqlalchemy.orm import joinedload

from app.models.product import Product
from app.lib.repository.base import BaseRepository


class ProductRepository(BaseRepository[Product]):
    """
    Repository de Product baseado em BaseRepository.
    - CRUD herdado: create, update, delete (soft), restore, get_by_id, get_active, get_deleted…
    - Aqui entram apenas consultas específicas de domínio (busca, paginação, checagens).
    """

    # Ativa soft-delete para este repository
    ENABLE_SOFT_DELETE: bool = True

    def __init__(self) -> None:
        super().__init__(Product)

    # Obrigatório pelo BaseRepository (contrato de busca simples)
    def find_by_criteria(self, criteria: Dict[str, Any]) -> List[Product]:
        # delega para o helper genérico
        return super().find_by_multiple_criteria(criteria, operator="AND")

    # --------------------- Consultas específicas --------------------- #
    def exists_name(self, name: str, *, exclude_id: Optional[int] = None) -> bool:
        q = Product.query
        q = q.filter(func.lower(Product.name) == func.lower(name))
        if exclude_id:
            q = q.filter(Product.id != exclude_id)
        # respeita soft-delete: BaseRepository.get_active usa deleted_at;
        # aqui garantimos que só conte itens não deletados logicamente
        if hasattr(Product, "deleted_at"):
            q = q.filter(Product.deleted_at.is_(None))
        return q.count() > 0

    def search_paginated(
        self,
        q: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        order_by: str | None = None,
        order_desc: bool = False,
        with_related: bool = False,
    ) -> Tuple[List[Product], int]:
        """
        Busca com paginação/ordenação. Opcionalmente faz eager-load de relações.
        Respeita soft-delete (exclui itens com deleted_at != NULL).
        """
        query = Product.query
        if hasattr(Product, "deleted_at"):
            query = query.filter(Product.deleted_at.is_(None))

        if with_related and hasattr(Product, "mine"):
            query = query.options(joinedload(Product.mine))

        if q:
            like = f"%{q.strip()}%"
            conds = [Product.name.ilike(like)]
            if hasattr(Product, "description"):
                conds.append(Product.description.ilike(like))
            if hasattr(Product, "code"):
                conds.append(Product.code.ilike(like))
            query = query.filter(or_(*conds))

        # ordenação (whitelist segura)
        order_col = {
            "id": Product.id,
            "name": Product.name,
            "created_at": getattr(Product, "created_at", Product.id),
            "updated_at": getattr(Product, "updated_at", Product.id),
        }.get((order_by or "id").lower(), Product.id)

        query = query.order_by(order_col.desc() if order_desc else order_col.asc())

        total = query.count()
        items = query.offset((page - 1) * per_page).limit(per_page).all()
        return items, total

    def get_by_ids(
        self,
        ids: Sequence[int],
        *,
        with_related: bool = False,
    ) -> List[Product]:
        query = Product.query.filter(Product.id.in_(list(ids)))
        if hasattr(Product, "deleted_at"):
            query = query.filter(Product.deleted_at.is_(None))
        if with_related and hasattr(Product, "mine"):
            query = query.options(joinedload(Product.mine))
        return query.all()
