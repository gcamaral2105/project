from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Tuple

from sqlalchemy import asc, desc, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.lib.repository.base import BaseRepository
from app.lib.repository.mixins import FilterableRepositoryMixin
from app.models.product import Product, Mine  # Mine lives in product.py in your repo


class SQLAlchemyProductRepository(BaseRepository[Product], FilterableRepositoryMixin):
    """Repository for Product with helpers to manage a mine's product set."""

    model = Product

    def __init__(self, session: Session) -> None:
        super().__init__(session=session)

    # ---------------------------- basic getters ---------------------------- #
    def get_by_id_and_mine(self, product_id: int, mine_id: int) -> Optional[Product]:
        q = select(Product).where(Product.id == product_id, Product.mine_id == mine_id, Product.deleted_at.is_(None))
        return self.session.execute(q).scalars().first()

    def get_by_code_and_mine(self, code: str, mine_id: int, *, include_deleted: bool = False) -> Optional[Product]:
        conds = [Product.code == code, Product.mine_id == mine_id]
        if not include_deleted:
            conds.append(Product.deleted_at.is_(None))
        q = select(Product).where(*conds)
        return self.session.execute(q).scalars().first()

    # ---------------------------- pagination/list -------------------------- #
    def paginate(
        self,
        page: int = 1,
        per_page: int = 20,
        *,
        mine_id: Optional[int] = None,
        name: Optional[str] = None,
        code: Optional[str] = None,
        q: Optional[str] = None,
        sort_by: str = "id",
        sort_dir: str = "asc",
        include_deleted: bool = False,
    ) -> Dict[str, Any]:
        query = select(Product)
        if mine_id is not None:
            query = query.where(Product.mine_id == mine_id)
        if name:
            query = query.where(Product.name.ilike(f"%{name}%"))
        if code:
            query = query.where(Product.code.ilike(f"%{code}%"))
        if q:
            query = query.where(or_(Product.name.ilike(f"%{q}%"), Product.code.ilike(f"%{q}%")))
        if not include_deleted:
            query = query.where(Product.deleted_at.is_(None))

        sort_col = getattr(Product, sort_by, Product.id)
        order_by = asc(sort_col) if sort_dir.lower() != "desc" else desc(sort_col)
        query = query.order_by(order_by)

        return self._paginate_query(query, page=page, per_page=per_page)

    # ----------------------- creation / updates (single) -------------------- #
    def create_for_mine(self, mine: Mine, data: Dict[str, Any]) -> Product:
        obj = Product(
            mine_id=mine.id,
            name=data.get("name"),
            code=data.get("code"),
            description=data.get("description"),
        )
        self.session.add(obj)
        self.session.flush()  # PK available; integrity checked later by service/transaction
        return obj

    def update_fields(self, product: Product, data: Dict[str, Any]) -> Product:
        for f in ["name", "code", "description"]:
            if f in data:
                setattr(product, f, data[f])
        self.session.flush()
        return product

    # ----------------------- bulk helpers for one mine ---------------------- #
    def upsert_many_for_mine(
        self,
        mine: Mine,
        items: List[Dict[str, Any]],
        *,
        match_by: Tuple[str, ...] = ("id", "code"),
        delete_missing: bool = False,
    ) -> Dict[str, Any]:
        """
        Synchronize the product set of a mine with `items`.

        Each item may contain:
          - id (int) OR code (str) to match existing products
          - name, description
          - _action="delete" to force deletion of that specific item

        Behavior:
          1) If _action == "delete": soft-delete (if found)
          2) Else match on ('id' -> first, then 'code' if provided)
             - if found: update fields
             - if not found: create new
          3) If delete_missing=True: any existing product not matched by the
             incoming set is soft-deleted.

        Returns dict with lists of: created, updated, deleted, unchanged (ids).
        """
        created, updated, deleted, unchanged = [], [], [], []

        # Preload all existing (including deleted if we want to "restore")
        existing_q = select(Product).where(Product.mine_id == mine.id)
        existing = {p.id: p for p in self.session.execute(existing_q).scalars().all()}
        matched_ids: set[int] = set()

        # Fast index by code for matching
        code_index: Dict[str, Product] = {}
        for p in existing.values():
            if p.code:
                code_index[p.code] = p

        # Process incoming items
        for raw in items:
            action = (raw.get("_action") or "").lower().strip()
            pid = raw.get("id")
            code = raw.get("code")

            # Match product
            product: Optional[Product] = None
            if pid is not None and pid in existing:
                product = existing[pid]
            elif code:
                product = code_index.get(code)

            if action == "delete":
                if product and product.deleted_at is None:
                    self.soft_delete(product)
                    deleted.append(product.id)
                    matched_ids.add(product.id)
                # if not found or already deleted -> ignore quietly
                continue

            if product is None:
                # create
                product = self.create_for_mine(mine, raw)
                created.append(product.id)
                matched_ids.add(product.id)
                continue

            # If found and not asked to delete -> maybe update
            before = (product.name, product.code, product.description)
            self.update_fields(product, raw)
            after = (product.name, product.code, product.description)

            if before == after:
                unchanged.append(product.id)
            else:
                updated.append(product.id)
            matched_ids.add(product.id)

        if delete_missing:
            # Soft-delete everything not matched in this sync
            for pid, prod in existing.items():
                if pid not in matched_ids and prod.deleted_at is None:
                    self.soft_delete(prod)
                    deleted.append(pid)

        return {
            "created": created,
            "updated": updated,
            "deleted": deleted,
            "unchanged": unchanged,
        }

    def create_products_for_mine(self, mine: Mine, items: Iterable[Dict[str, Any]]) -> List[Product]:
        objs: List[Product] = []
        for data in items:
            objs.append(self.create_for_mine(mine, data))
        self.session.flush()
        return objs
