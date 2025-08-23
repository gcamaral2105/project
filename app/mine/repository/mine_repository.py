from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Optional, Sequence

from sqlalchemy import asc, desc, or_, select
from sqlalchemy.orm import Session

from app.extensions import db
from app.models.mine import Mine


@dataclass
class Page:
    items: list
    total: int
    page: int
    per_page: int
    pages: int


@dataclass
class MineFilter:
    country: Optional[str] = None
    q: Optional[str] = None
    include_deleted: bool = False


@dataclass
class MineSort:
    field: str = "id"
    direction: str = "asc"


class SQLAlchemyMineRepository:
    """
    Simple repository specializing on Mine with soft-delete support.
    """

    def __init__(self, session: Optional[Session] = None) -> None:
        self.session = session or db.session

    # ------------------- queries -------------------
    def _base_query(self, flt: MineFilter | None) -> Any:
        stmt = select(Mine)
        if not flt or not flt.include_deleted:
            stmt = stmt.where(Mine.deleted_at.is_(None))

        if flt:
            if flt.country:
                stmt = stmt.where(Mine.country == flt.country)
            if flt.q:
                pattern = f"%{flt.q.strip()}%"
                stmt = stmt.where(
                    or_(Mine.name.ilike(pattern), Mine.city.ilike(pattern), Mine.country.ilike(pattern))
                )
        return stmt

    def _apply_sort(self, stmt: Any, sort: MineSort | None) -> Any:
        sort = sort or MineSort()
        col = getattr(Mine, sort.field, Mine.id)
        direction = asc if (sort.direction or "asc").lower() == "asc" else desc
        return stmt.order_by(direction(col))

    def list(
        self,
        flt: MineFilter | None = None,
        sort: MineSort | None = None,
        page: int = 1,
        per_page: int = 20,
        with_products: bool = False,  # kept for API symmetry, not used here
    ) -> Page:
        stmt = self._apply_sort(self._base_query(flt), sort)
        total = self.session.execute(stmt.with_only_columns(Mine.id)).scalars().unique().count()
        if page < 1:
            page = 1
        if per_page < 1:
            per_page = 20
        offset = (page - 1) * per_page
        items = self.session.execute(stmt.offset(offset).limit(per_page)).scalars().all()
        pages = (total + per_page - 1) // per_page if per_page else 1
        return Page(items=items, total=total, page=page, per_page=per_page, pages=pages)

    def get(self, mine_id: int, with_products: bool = False) -> Optional[Mine]:
        stmt = select(Mine).where(Mine.id == mine_id)
        return self.session.execute(stmt).scalars().first()

    # ------------------- mutations -------------------
    def create(self, payload: Dict[str, Any]) -> Mine:
        entity = Mine(
            name=(payload.get("name") or "").strip(),
            code=(payload.get("code") or None),
            country=payload.get("country"),
            state=payload.get("state"),
            city=payload.get("city"),
            latitude=payload.get("latitude"),
            longitude=payload.get("longitude"),
            berths=payload.get("berths", 1),
            shiploaders=payload.get("shiploaders", 1),
            is_active=payload.get("is_active", True),
        )
        self.session.add(entity)
        self.session.flush()  # assign PK
        return entity

    def update_fields(self, mine_id: int, payload: Dict[str, Any]) -> Mine:
        entity = self.get(mine_id)
        if not entity:
            raise ValueError("Mine not found")
        for field in [
            "name",
            "code",
            "country",
            "state",
            "city",
            "latitude",
            "longitude",
            "berths",
            "shiploaders",
            "is_active",
        ]:
            if field in payload:
                setattr(entity, field, payload[field])
        self.session.flush()
        return entity

    def delete(self, mine_id: int, soft: bool = True) -> None:
        entity = self.get(mine_id)
        if not entity:
            return
        if soft:
            entity.deleted_at = datetime.utcnow()
            self.session.flush()
        else:
            self.session.delete(entity)
            self.session.flush()

    def restore(self, mine_id: int) -> None:
        entity = self.get(mine_id)
        if not entity:
            return
        entity.deleted_at = None
        self.session.flush()
