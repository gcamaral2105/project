from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional

from sqlalchemy import asc, desc, or_, select
from sqlalchemy.orm import Session

from app.lib.repository.base import BaseRepository
from app.lib.repository.mixins import FilterableRepositoryMixin
from app.models.product import Mine  # In your project, Mine is declared in product.py
from app.product.repository.product_repository import SQLAlchemyProductRepository


class SQLAlchemyMineRepository(BaseRepository[Mine], FilterableRepositoryMixin):
    """Repository for Mine + helpers to manage products in one transaction."""

    model = Mine

    def __init__(self, session: Session) -> None:
        super().__init__(session=session)
        self.product_repo = SQLAlchemyProductRepository(session)

    # ---------------------------- pagination/list --------------------------- #
    def paginate(
        self,
        page: int = 1,
        per_page: int = 20,
        *,
        name: str | None = None,
        code: str | None = None,
        country: str | None = None,
        q: str | None = None,
        sort_by: str = "id",
        sort_dir: str = "asc",
        include_deleted: bool = False,
    ) -> Dict[str, Any]:
        query = select(Mine)
        if name:
            query = query.where(Mine.name.ilike(f"%{name}%"))
        if code:
            query = query.where(Mine.code.ilike(f"%{code}%"))
        if country:
            query = query.where(Mine.country.ilike(f"%{country}%"))
        if q:
            query = query.where(
                or_(
                    Mine.name.ilike(f"%{q}%"),
                    Mine.code.ilike(f"%{q}%"),
                    Mine.country.ilike(f"%{q}%"),
                )
            )
        if not include_deleted:
            query = query.where(Mine.deleted_at.is_(None))

        sort_col = getattr(Mine, sort_by, Mine.id)
        order_by = asc(sort_col) if sort_dir.lower() != "desc" else desc(sort_col)
        query = query.order_by(order_by)

        return self._paginate_query(query, page=page, per_page=per_page)

    # ---------------------------- nested helpers ---------------------------- #
    def create_with_products(self, mine_data: Dict[str, Any], products: Iterable[Dict[str, Any]] | None = None) -> Mine:
        mine = Mine(
            name=mine_data.get("name"),
            code=mine_data.get("code"),
            country=mine_data.get("country"),
            description=mine_data.get("description"),
        )
        self.session.add(mine)
        self.session.flush()  # get mine.id

        if products:
            self.product_repo.create_products_for_mine(mine, products)

        return mine

    def sync_products_for_mine(
        self,
        mine: Mine,
        items: List[Dict[str, Any]],
        *,
        delete_missing: bool = False,
    ) -> Dict[str, Any]:
        """
        Delegate to product repo to upsert/soft-delete products for a mine.
        """
        return self.product_repo.upsert_many_for_mine(
            mine,
            items,
            match_by=("id", "code"),
            delete_missing=delete_missing,
        )
