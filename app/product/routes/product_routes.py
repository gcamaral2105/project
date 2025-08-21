from __future__ import annotations

"""
Robust Repository layer for Product, decoupled from Flask and controllers.

Key features
------------
- Typed interface (protocol) + concrete SQLAlchemy implementation
- Rich filtering (mine_id, name/code search, full-text like, created/updated ranges)
- Sorting (id/name/created_at), safe white-listed
- Pagination helper (Page[T])
- Eager loading toggle for Mine (joinedload)
- Soft-delete aware (respects `deleted_at` if present on BaseModel)
- IntegrityError -> domain errors (DuplicateError)
- Optional SELECT ... FOR UPDATE locking
- Batch helpers (bulk_create, get_by_ids)

Usage (example)
---------------

    from sqlalchemy.orm import Session
    from app.models.product import Product

    repo = SQLAlchemyProductRepository(session)
    page = repo.list(ProductFilter(mine_id=1, q="bx"), page=1, per_page=20)
    for pr in page.items:
        print(pr.to_dict(include_audit=False))

"""

from dataclasses import dataclass
from datetime import datetime, date
from typing import Any, Dict, Generic, Iterable, List, Optional, Protocol, Sequence, Tuple, TypeVar

from sqlalchemy import Select, and_, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, joinedload

from app.models.product import Product

# ---------------------------------------------------------------------------
# Pagination + Errors
# ---------------------------------------------------------------------------
T = TypeVar("T")


@dataclass(slots=True)
class Page(Generic[T]):
    items: List[T]
    page: int
    per_page: int
    total: int

    @property
    def pages(self) -> int:
        if self.per_page <= 0:
            return 1
        return max(1, (self.total + self.per_page - 1) // self.per_page)


class RepositoryError(RuntimeError):
    pass


class NotFoundError(RepositoryError):
    pass


class DuplicateError(RepositoryError):
    pass


class ConcurrencyError(RepositoryError):
    pass


# ---------------------------------------------------------------------------
# Filters & Sorting
# ---------------------------------------------------------------------------
@dataclass(slots=True)
class ProductFilter:
    mine_id: Optional[int] = None
    name: Optional[str] = None  # exact match
    code: Optional[str] = None  # exact match if your Product has code
    q: Optional[str] = None     # ilike search over name/code

    include_deleted: bool = False
    only_deleted: bool = False

    created_from: Optional[date] = None
    created_to: Optional[date] = None
    updated_from: Optional[date] = None
    updated_to: Optional[date] = None


@dataclass(slots=True)
class ProductSort:
    # Allowed values
    field: str = "id"  # id | name | created_at | updated_at
    direction: str = "asc"  # asc | desc

    def apply(self, stmt: Select, model: type[Product]) -> Select:
        field_map = {
            "id": model.id,
            "name": model.name,
            "created_at": getattr(model, "created_at", model.id),
            "updated_at": getattr(model, "updated_at", model.id),
        }
        col = field_map.get(self.field, model.id)
        order = col.asc() if self.direction.lower() != "desc" else col.desc()
        return stmt.order_by(order)


# ---------------------------------------------------------------------------
# Repository Protocol (Interface)
# ---------------------------------------------------------------------------
class IProductRepository(Protocol):
    def get(self, id: int, *, with_mine: bool = False, include_deleted: bool = False, for_update: bool = False) -> Optional[Product]:
        ...

    def get_or_fail(self, id: int, **kwargs: Any) -> Product:
        ...

    def get_by_ids(self, ids: Sequence[int], *, with_mine: bool = False, include_deleted: bool = False) -> List[Product]:
        ...

    def exists_by_name(self, name: str, *, mine_id: Optional[int] = None, exclude_id: Optional[int] = None) -> bool:
        ...

    def list(
        self,
        flt: Optional[ProductFilter] = None,
        *,
        sort: Optional[ProductSort] = None,
        page: int = 1,
        per_page: int = 20,
        with_mine: bool = False,
    ) -> Page[Product]:
        ...

    def add(self, entity: Product) -> Product:
        ...

    def create(self, data: Dict[str, Any]) -> Product:
        ...

    def update_fields(self, id: int, data: Dict[str, Any]) -> Product:
        ...

    def delete(self, id: int, *, soft: bool = True, deleted_by: Optional[str] = None) -> None:
        ...

    def restore(self, id: int) -> None:
        ...

    def count_by_mine(self, mine_id: int) -> int:
        ...


# ---------------------------------------------------------------------------
# SQLAlchemy Implementation
# ---------------------------------------------------------------------------
class SQLAlchemyProductRepository(IProductRepository):
    def __init__(self, session: Session):
        self.session = session

    # ----------------------------- helpers ---------------------------------
    @staticmethod
    def _base_stmt(with_mine: bool = False, include_deleted: bool = False) -> Select:
        stmt = select(Product)
        if with_mine:
            stmt = stmt.options(joinedload(Product.mine))
        if not include_deleted and hasattr(Product, "deleted_at"):
            stmt = stmt.where(getattr(Product, "deleted_at") == None)  # noqa: E711
        return stmt

    @staticmethod
    def _apply_filter(stmt: Select, flt: Optional[ProductFilter]) -> Select:
        if not flt:
            return stmt

        conds = []
        if flt.only_deleted and hasattr(Product, "deleted_at"):
            conds.append(getattr(Product, "deleted_at") != None)  # noqa: E711
        elif not flt.include_deleted and hasattr(Product, "deleted_at"):
            conds.append(getattr(Product, "deleted_at") == None)  # noqa: E711

        if flt.mine_id is not None:
            conds.append(Product.mine_id == flt.mine_id)
        if flt.name:
            conds.append(Product.name == flt.name)
        if flt.code and hasattr(Product, "code"):
            conds.append(getattr(Product, "code") == flt.code)
        if flt.q:
            q = f"%{flt.q.strip()}%"
            if hasattr(Product, "code"):
                conds.append(and_(Product.name.ilike(q) | getattr(Product, "code").ilike(q)))
            else:
                conds.append(Product.name.ilike(q))

        if flt.created_from and hasattr(Product, "created_at"):
            conds.append(getattr(Product, "created_at") >= datetime.combine(flt.created_from, datetime.min.time()))
        if flt.created_to and hasattr(Product, "created_at"):
            conds.append(getattr(Product, "created_at") <= datetime.combine(flt.created_to, datetime.max.time()))
        if flt.updated_from and hasattr(Product, "updated_at"):
            conds.append(getattr(Product, "updated_at") >= datetime.combine(flt.updated_from, datetime.min.time()))
        if flt.updated_to and hasattr(Product, "updated_at"):
            conds.append(getattr(Product, "updated_at") <= datetime.combine(flt.updated_to, datetime.max.time()))

        if conds:
            stmt = stmt.where(and_(*conds))
        return stmt

    # ------------------------------ reads ----------------------------------
    def get(self, id: int, *, with_mine: bool = False, include_deleted: bool = False, for_update: bool = False) -> Optional[Product]:
        stmt = self._base_stmt(with_mine=with_mine, include_deleted=include_deleted).where(Product.id == id)
        if for_update:
            stmt = stmt.with_for_update()
        return self.session.execute(stmt).scalars().first()

    def get_or_fail(self, id: int, **kwargs: Any) -> Product:
        entity = self.get(id, **kwargs)
        if not entity:
            raise NotFoundError(f"Product {id} not found")
        return entity

    def get_by_ids(self, ids: Sequence[int], *, with_mine: bool = False, include_deleted: bool = False) -> List[Product]:
        if not ids:
            return []
        stmt = self._base_stmt(with_mine=with_mine, include_deleted=include_deleted).where(Product.id.in_(list(ids)))
        return list(self.session.execute(stmt).scalars().all())

    def exists_by_name(self, name: str, *, mine_id: Optional[int] = None, exclude_id: Optional[int] = None) -> bool:
        stmt = select(func.count(Product.id)).where(Product.name == name)
        if mine_id is not None:
            stmt = stmt.where(Product.mine_id == mine_id)
        if exclude_id is not None:
            stmt = stmt.where(Product.id != exclude_id)
        if hasattr(Product, "deleted_at"):
            stmt = stmt.where(getattr(Product, "deleted_at") == None)  # noqa: E711
        return self.session.execute(stmt).scalar_one() > 0

    def list(
        self,
        flt: Optional[ProductFilter] = None,
        *,
        sort: Optional[ProductSort] = None,
        page: int = 1,
        per_page: int = 20,
        with_mine: bool = False,
    ) -> Page[Product]:
        if page <= 0:
            page = 1
        if per_page <= 0:
            per_page = 20

        base = self._base_stmt(with_mine=with_mine, include_deleted=True)  # filter decides deletion view
        filtered = self._apply_filter(base, flt)
        total = self.session.execute(select(func.count()).select_from(filtered.subquery())).scalar_one()

        stmt = filtered
        stmt = (sort or ProductSort()).apply(stmt, Product)
        stmt = stmt.offset((page - 1) * per_page).limit(per_page)
        rows = self.session.execute(stmt).scalars().all()
        return Page(items=list(rows), page=page, per_page=per_page, total=total)

    # ----------------------------- writes ----------------------------------
    def add(self, entity: Product) -> Product:
        self.session.add(entity)
        return entity

    def create(self, data: Dict[str, Any]) -> Product:
        entity = Product(**data)
        self.session.add(entity)
        try:
            self.session.flush()  # obtain PK early + catch IntegrityError here
        except IntegrityError as e:
            raise DuplicateError(str(e)) from e
        return entity

    def update_fields(self, id: int, data: Dict[str, Any]) -> Product:
        entity = self.get_or_fail(id, with_mine=False, include_deleted=True, for_update=True)
        for k, v in data.items():
            if not hasattr(entity, k):
                continue
            setattr(entity, k, v)
        try:
            self.session.flush()
        except IntegrityError as e:
            raise DuplicateError(str(e)) from e
        return entity

    def delete(self, id: int, *, soft: bool = True, deleted_by: Optional[str] = None) -> None:
        entity = self.get_or_fail(id, include_deleted=True, for_update=True)
        if soft and hasattr(entity, "deleted_at"):
            setattr(entity, "deleted_at", datetime.utcnow())
            if deleted_by is not None and hasattr(entity, "deleted_by"):
                setattr(entity, "deleted_by", deleted_by)
            self.session.flush()
        else:
            self.session.delete(entity)

    def restore(self, id: int) -> None:
        entity = self.get_or_fail(id, include_deleted=True, for_update=True)
        if hasattr(entity, "deleted_at"):
            setattr(entity, "deleted_at", None)
            if hasattr(entity, "deleted_by"):
                setattr(entity, "deleted_by", None)
            self.session.flush()
        else:
            # If hard-deleted, can't restore.
            raise NotFoundError(f"Product {id} cannot be restored (no soft-delete fields)")

    def count_by_mine(self, mine_id: int) -> int:
        stmt = select(func.count(Product.id)).where(Product.mine_id == mine_id)
        if hasattr(Product, "deleted_at"):
            stmt = stmt.where(getattr(Product, "deleted_at") == None)  # noqa: E711
        return self.session.execute(stmt).scalar_one()


# ---------------------------------------------------------------------------
# Optional: very small Unit of Work for explicit transaction control
# ---------------------------------------------------------------------------
class UnitOfWork(Protocol):
    session: Session
    def commit(self) -> None: ...
    def rollback(self) -> None: ...


class SQLAlchemyUnitOfWork:
    """Simple UoW that manages a Session lifecycle. In many Flask apps you
    already have a scoped/session per request; this is just an example for
    scripts, CLIs or background jobs.
    """

    def __init__(self, session_factory):
        self._session_factory = session_factory
        self.session: Optional[Session] = None

    def __enter__(self) -> "SQLAlchemyUnitOfWork":
        self.session = self._session_factory()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        try:
            if exc:
                self.rollback()
            else:
                self.commit()
        finally:
            if self.session is not None:
                self.session.close()

    # UoW API
    def commit(self) -> None:
        if self.session is not None:
            self.session.commit()

    def rollback(self) -> None:
        if self.session is not None:
            self.session.rollback()

    # Convenience factory
    def product_repo(self) -> SQLAlchemyProductRepository:
        if self.session is None:
            raise RuntimeError("UnitOfWork has no active session")
        return SQLAlchemyProductRepository(self.session)
