"""
Mine Repository
===============

Repository layer for Mine data access following the same pattern as ProductRepository.
Provides typed interface and SQLAlchemy implementation with advanced features.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, date
from typing import Any, Dict, Generic, Iterable, List, Optional, Protocol, Sequence, Tuple, TypeVar

from sqlalchemy import Select, and_, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, joinedload

from app.models.product import Mine

# ---------------------------------------------------------------------------
# Pagination + Errors (reusing from product repository)
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
class MineFilter:
    name: Optional[str] = None  # exact match
    code: Optional[str] = None  # exact match
    country: Optional[str] = None  # exact match
    q: Optional[str] = None     # ilike search over name/code/country

    include_deleted: bool = False
    only_deleted: bool = False

    created_from: Optional[date] = None
    created_to: Optional[date] = None
    updated_from: Optional[date] = None
    updated_to: Optional[date] = None


@dataclass(slots=True)
class MineSort:
    # Allowed values
    field: str = "id"  # id | name | country | created_at | updated_at
    direction: str = "asc"  # asc | desc

    def apply(self, stmt: Select, model: type[Mine]) -> Select:
        field_map = {
            "id": model.id,
            "name": model.name,
            "country": model.country,
            "created_at": getattr(model, "created_at", model.id),
            "updated_at": getattr(model, "updated_at", model.id),
        }
        col = field_map.get(self.field, model.id)
        order = col.asc() if self.direction.lower() != "desc" else col.desc()
        return stmt.order_by(order)


# ---------------------------------------------------------------------------
# Repository Protocol (Interface)
# ---------------------------------------------------------------------------
class IMineRepository(Protocol):
    def get(self, id: int, *, with_products: bool = False, include_deleted: bool = False, for_update: bool = False) -> Optional[Mine]:
        ...

    def get_or_fail(self, id: int, **kwargs: Any) -> Mine:
        ...

    def get_by_ids(self, ids: Sequence[int], *, with_products: bool = False, include_deleted: bool = False) -> List[Mine]:
        ...

    def exists_by_name(self, name: str, *, exclude_id: Optional[int] = None) -> bool:
        ...

    def exists_by_code(self, code: str, *, exclude_id: Optional[int] = None) -> bool:
        ...

    def list(
        self,
        flt: Optional[MineFilter] = None,
        *,
        sort: Optional[MineSort] = None,
        page: int = 1,
        per_page: int = 20,
        with_products: bool = False,
    ) -> Page[Mine]:
        ...

    def add(self, entity: Mine) -> Mine:
        ...

    def create(self, data: Dict[str, Any]) -> Mine:
        ...

    def update_fields(self, id: int, data: Dict[str, Any]) -> Mine:
        ...

    def delete(self, id: int, *, soft: bool = True, deleted_by: Optional[str] = None) -> None:
        ...

    def restore(self, id: int) -> None:
        ...

    def count_by_country(self, country: str) -> int:
        ...


# ---------------------------------------------------------------------------
# SQLAlchemy Implementation
# ---------------------------------------------------------------------------
class SQLAlchemyMineRepository(IMineRepository):
    def __init__(self, session: Session):
        self.session = session

    # ----------------------------- helpers ---------------------------------
    @staticmethod
    def _base_stmt(with_products: bool = False, include_deleted: bool = False) -> Select:
        stmt = select(Mine)
        if with_products:
            stmt = stmt.options(joinedload(Mine.products))
        if not include_deleted and hasattr(Mine, "deleted_at"):
            stmt = stmt.where(getattr(Mine, "deleted_at") == None)  # noqa: E711
        return stmt

    @staticmethod
    def _apply_filter(stmt: Select, flt: Optional[MineFilter]) -> Select:
        if not flt:
            return stmt

        conds = []
        if flt.only_deleted and hasattr(Mine, "deleted_at"):
            conds.append(getattr(Mine, "deleted_at") != None)  # noqa: E711
        elif not flt.include_deleted and hasattr(Mine, "deleted_at"):
            conds.append(getattr(Mine, "deleted_at") == None)  # noqa: E711

        if flt.name:
            conds.append(Mine.name == flt.name)
        if flt.code:
            conds.append(Mine.code == flt.code)
        if flt.country:
            conds.append(Mine.country == flt.country)
        if flt.q:
            q = f"%{flt.q.strip()}%"
            search_conditions = [Mine.name.ilike(q), Mine.country.ilike(q)]
            if hasattr(Mine, "code"):
                search_conditions.append(Mine.code.ilike(q))
            conds.append(and_(*search_conditions) if len(search_conditions) == 1 else func.or_(*search_conditions))

        if flt.created_from and hasattr(Mine, "created_at"):
            conds.append(getattr(Mine, "created_at") >= datetime.combine(flt.created_from, datetime.min.time()))
        if flt.created_to and hasattr(Mine, "created_at"):
            conds.append(getattr(Mine, "created_at") <= datetime.combine(flt.created_to, datetime.max.time()))
        if flt.updated_from and hasattr(Mine, "updated_at"):
            conds.append(getattr(Mine, "updated_at") >= datetime.combine(flt.updated_from, datetime.min.time()))
        if flt.updated_to and hasattr(Mine, "updated_at"):
            conds.append(getattr(Mine, "updated_at") <= datetime.combine(flt.updated_to, datetime.max.time()))

        if conds:
            stmt = stmt.where(and_(*conds))
        return stmt

    # ------------------------------ reads ----------------------------------
    def get(self, id: int, *, with_products: bool = False, include_deleted: bool = False, for_update: bool = False) -> Optional[Mine]:
        stmt = self._base_stmt(with_products=with_products, include_deleted=include_deleted).where(Mine.id == id)
        if for_update:
            stmt = stmt.with_for_update()
        return self.session.execute(stmt).scalars().first()

    def get_or_fail(self, id: int, **kwargs: Any) -> Mine:
        entity = self.get(id, **kwargs)
        if not entity:
            raise NotFoundError(f"Mine {id} not found")
        return entity

    def get_by_ids(self, ids: Sequence[int], *, with_products: bool = False, include_deleted: bool = False) -> List[Mine]:
        if not ids:
            return []
        stmt = self._base_stmt(with_products=with_products, include_deleted=include_deleted).where(Mine.id.in_(list(ids)))
        return list(self.session.execute(stmt).scalars().all())

    def exists_by_name(self, name: str, *, exclude_id: Optional[int] = None) -> bool:
        stmt = select(func.count(Mine.id)).where(Mine.name == name)
        if exclude_id is not None:
            stmt = stmt.where(Mine.id != exclude_id)
        if hasattr(Mine, "deleted_at"):
            stmt = stmt.where(getattr(Mine, "deleted_at") == None)  # noqa: E711
        return self.session.execute(stmt).scalar_one() > 0

    def exists_by_code(self, code: str, *, exclude_id: Optional[int] = None) -> bool:
        if not code:
            return False
        stmt = select(func.count(Mine.id)).where(Mine.code == code)
        if exclude_id is not None:
            stmt = stmt.where(Mine.id != exclude_id)
        if hasattr(Mine, "deleted_at"):
            stmt = stmt.where(getattr(Mine, "deleted_at") == None)  # noqa: E711
        return self.session.execute(stmt).scalar_one() > 0

    def list(
        self,
        flt: Optional[MineFilter] = None,
        *,
        sort: Optional[MineSort] = None,
        page: int = 1,
        per_page: int = 20,
        with_products: bool = False,
    ) -> Page[Mine]:
        if page <= 0:
            page = 1
        if per_page <= 0:
            per_page = 20

        base = self._base_stmt(with_products=with_products, include_deleted=True)  # filter decides deletion view
        filtered = self._apply_filter(base, flt)
        total = self.session.execute(select(func.count()).select_from(filtered.subquery())).scalar_one()

        stmt = filtered
        stmt = (sort or MineSort()).apply(stmt, Mine)
        stmt = stmt.offset((page - 1) * per_page).limit(per_page)
        rows = self.session.execute(stmt).scalars().all()
        return Page(items=list(rows), page=page, per_page=per_page, total=total)

    # ----------------------------- writes ----------------------------------
    def add(self, entity: Mine) -> Mine:
        self.session.add(entity)
        return entity

    def create(self, data: Dict[str, Any]) -> Mine:
        entity = Mine(**data)
        self.session.add(entity)
        try:
            self.session.flush()  # obtain PK early + catch IntegrityError here
        except IntegrityError as e:
            raise DuplicateError(str(e)) from e
        return entity

    def update_fields(self, id: int, data: Dict[str, Any]) -> Mine:
        entity = self.get_or_fail(id, with_products=False, include_deleted=True, for_update=True)
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
            raise NotFoundError(f"Mine {id} cannot be restored (no soft-delete fields)")

    def count_by_country(self, country: str) -> int:
        stmt = select(func.count(Mine.id)).where(Mine.country == country)
        if hasattr(Mine, "deleted_at"):
            stmt = stmt.where(getattr(Mine, "deleted_at") == None)  # noqa: E711
        return self.session.execute(stmt).scalar_one()

