from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Optional

from sqlalchemy import asc, desc, or_, select
from sqlalchemy.orm import Session

from app.extensions import db
from app.models.product import Product


@dataclass
class Page:
    items: list
    total: int
    page: int
    per_page: int
    pages: int


class ProductRepository:
    def __init__(self, session: Optional[Session] = None) -> None:
        self.session = session or db.session

    # ------------------- read -------------------
    def _base(self, include_deleted: bool = False, q: str | None = None) -> Any:
        stmt = select(Product)
        if not include_deleted:
            stmt = stmt.where(Product.deleted_at.is_(None))
        if q:
            pattern = f"%{q.strip()}%"
            stmt = stmt.where(
                or_(Product.name.ilike(pattern), Product.code.ilike(pattern))
            )
        return stmt

    def paginate(
        self,
        *,
        page: int = 1,
        per_page: int = 20,
        include_deleted: bool = False,
        q: str | None = None,
        sort_by: str = "id",
        sort_direction: str = "asc",
    ) -> Page:
        stmt = self._base(include_deleted=include_deleted, q=q)
        col = getattr(Product, sort_by, Product.id)
        direction = asc if (sort_direction or "asc").lower() == "asc" else desc
        stmt = stmt.order_by(direction(col))

        total = self.session.execute(stmt.with_only_columns(Product.id)).scalars().unique().count()
        page = max(1, int(page or 1))
        per_page = max(1, int(per_page or 20))
        offset = (page - 1) * per_page
        items = self.session.execute(stmt.offset(offset).limit(per_page)).scalars().all()
        pages = (total + per_page - 1) // per_page if per_page else 1
        return Page(items=items, total=total, page=page, per_page=per_page, pages=pages)

    def get(self, product_id: int) -> Optional[Product]:
        stmt = select(Product).where(Product.id == product_id)
        return self.session.execute(stmt).scalars().first()

    # ------------------- write -------------------
    def create(self, payload: Dict[str, Any]) -> Product:
        entity = Product(
            name=(payload.get("name") or "").strip(),
            code=(payload.get("code") or None),
            category=payload.get("category"),
            subtype=payload.get("subtype"),
            mine_id=payload.get("mine_id"),
            unit=payload.get("unit"),
            is_active=payload.get("is_active", True),
        )
        self.session.add(entity)
        self.session.flush()
        return entity

    def update_fields(self, product_id: int, payload: Dict[str, Any]) -> Product:
        entity = self.get(product_id)
        if not entity:
            raise ValueError("Product not found")
        for field in ["name", "code", "category", "subtype", "mine_id", "unit", "is_active"]:
            if field in payload:
                setattr(entity, field, payload[field])
        self.session.flush()
        return entity

    def delete(self, product_id: int, soft: bool = True) -> None:
        entity = self.get(product_id)
        if not entity:
            return
        if soft:
            entity.deleted_at = datetime.utcnow()
            self.session.flush()
        else:
            self.session.delete(entity)
            self.session.flush()

    def restore(self, product_id: int) -> None:
        entity = self.get(product_id)
        if not entity:
            return
        entity.deleted_at = None
        self.session.flush()
