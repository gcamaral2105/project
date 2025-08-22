"""
Generic BaseRepository ­— type‑checker friendly
==============================================

Requires:
    pip install flask-sqlalchemy
    # (optional but recommended for typing)
    pip install flask-sqlalchemy-stubs
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import datetime
from typing import Any, Callable, Dict, Generic, List, Optional, Type, TypeVar, Union

from flask_sqlalchemy import SQLAlchemy
from flask_sqlalchemy.model import Model  # <- **static type, not a variable**
from sqlalchemy import and_, or_, select, func, text
from sqlalchemy.orm import with_for_update
from sqlalchemy.exc import IntegrityError as SQLIntegrityError

# --------------------------------------------------------------------------- #
# Set up your db instance elsewhere (e.g. app/extensions.py) and import here  #
# --------------------------------------------------------------------------- #
from app.extensions import db  # runtime instance of SQLAlchemy

# --------------------------------------------------------------------------- #
# Generic type variable for “the model managed by this repository”            #
# --------------------------------------------------------------------------- #
M = TypeVar("M", bound=Model)  # every repo instance will be tied to one model

# Hook signature: (entity_or_None, extra_payload) -> None
HookT = Callable[[Optional[M], Dict[str, Any]], None]


class BaseRepository(Generic[M], ABC):
    """A reusable repository with hooks, audit, and optional soft delete."""

    ENABLE_AUDIT: bool = True
    ENABLE_SOFT_DELETE: bool = False
    CACHE_TIMEOUT: int = 300  # seconds

    # ─────────────────────────── constructor ──────────────────────────── #
    def __init__(self, model_class: Type[M]) -> None:
        """
        Parameters
        ----------
        model_class
            The SQLAlchemy model class this repository will manage
            (e.g. ``Product`` or ``Client``).
        """
        self.model_class: Type[M] = model_class
        self.session = db.session

        # in‑memory registry of event hooks
        self._hooks: Dict[str, List[HookT]] = {
            "before_create": [],
            "after_create": [],
            "before_update": [],
            "after_update": [],
            "before_delete": [],
            "after_delete": [],
        }

    # ───────────────────────────── hooks api ───────────────────────────── #
    def add_hook(self, event: str, callback: HookT) -> None:
        if event not in self._hooks:
            raise ValueError(f"Unknown hook event: {event}")
        self._hooks[event].append(callback)

    def _fire(self, event: str, entity: Optional[M] = None, **payload: Any) -> None:
        for hook in self._hooks[event]:
            hook(entity, payload)

    # ───────────────────────────── crud api ────────────────────────────── #
    def create(self, **data: Any) -> M:
        try:
            if self.ENABLE_AUDIT:
                data |= self._audit_fields("create")

            self._fire("before_create", None, **data)

            entity: M = self.model_class(**data)  # type: ignore[arg-type]
            self.session.add(entity)
            self.session.commit()

            self._fire("after_create", entity)
            return entity
        except Exception as exc:
            self.session.rollback()
            raise self._translate_db_error(exc, "create") from exc

    def update(self, entity_id: Union[int, str], **changes: Any) -> Optional[M]:
        entity = self.get_by_id(entity_id)
        if entity is None:
            return None

        try:
            if self.ENABLE_AUDIT:
                changes |= self._audit_fields("update")

            self._fire("before_update", entity, **changes)

            for key, value in changes.items():
                if hasattr(entity, key):
                    setattr(entity, key, value)

            self.session.commit()

            self._fire("after_update", entity)
            return entity
        except Exception as exc:
            self.session.rollback()
            raise self._translate_db_error(exc, "update") from exc

    def delete(self, entity_id: Union[int, str]) -> bool:
        entity = self.get_by_id(entity_id)
        if entity is None:
            return False

        try:
            self._fire("before_delete", entity)

            if self.ENABLE_SOFT_DELETE and hasattr(entity, "deleted_at"):
                entity.deleted_at = datetime.utcnow()
                if self.ENABLE_AUDIT:
                    for k, v in self._audit_fields("delete").items():
                        if hasattr(entity, k):
                            setattr(entity, k, v)
            else:
                self.session.delete(entity)

            self.session.commit()
            self._fire("after_delete", entity)
            return True
        except Exception as exc:
            self.session.rollback()
            raise self._translate_db_error(exc, "delete") from exc

    def restore(self, entity_id: Union[int, str]) -> bool:
        if not (self.ENABLE_SOFT_DELETE and hasattr(self.model_class, "deleted_at")):
            return False

        try:
            entity: Optional[M] = (
                self.model_class.query.filter(
                    and_(
                        self.model_class.id == entity_id,  # type: ignore[attr-defined]
                        self.model_class.deleted_at.is_not(None),  # type: ignore[attr-defined]
                    )
                ).first()
            )

            if entity is None:
                return False

            entity.deleted_at = None  # type: ignore[attr-defined]
            if self.ENABLE_AUDIT:
                for k, v in self._audit_fields("restore").items():
                    if hasattr(entity, k):
                        setattr(entity, k, v)

            self.session.commit()
            return True
        except Exception as exc:
            self.session.rollback()
            raise self._translate_db_error(exc, "restore") from exc

    # ──────────────────────────── query api ────────────────────────────── #
    def get_by_id(self, entity_id: Union[int, str]) -> Optional[M]:
        return self.model_class.query.get(entity_id)

    def get_active(self) -> List[M]:
        query = self.model_class.query
        if self.ENABLE_SOFT_DELETE and hasattr(self.model_class, "deleted_at"):
            query = query.filter(self.model_class.deleted_at.is_(None))
        return query.all()

    def get_deleted(self) -> List[M]:
        if not (self.ENABLE_SOFT_DELETE and hasattr(self.model_class, "deleted_at")):
            return []
        return self.model_class.query.filter(
            self.model_class.deleted_at.is_not(None)
        ).all()

    def find_by_multiple_criteria(
        self, criteria: Dict[str, Any], operator: str = "AND"
    ) -> List[M]:
        query = self.model_class.query
        if self.ENABLE_SOFT_DELETE and hasattr(self.model_class, "deleted_at"):
            query = query.filter(self.model_class.deleted_at.is_(None))

        conditions = []
        for field, value in criteria.items():
            if not hasattr(self.model_class, field):
                continue
            column = getattr(self.model_class, field)

            if isinstance(value, dict):
                for op, val in value.items():
                    match op:
                        case "gt":
                            conditions.append(column > val)
                        case "lt":
                            conditions.append(column < val)
                        case "gte":
                            conditions.append(column >= val)
                        case "lte":
                            conditions.append(column <= val)
                        case "like":
                            conditions.append(column.like(val))
                        case "ilike":
                            conditions.append(column.ilike(val))
                        case "in":
                            conditions.append(column.in_(val))
                        case _:
                            raise ValueError(f"Unsupported operator: {op}")
            else:
                conditions.append(column == value)

        if conditions:
            query = query.filter(
                or_(*conditions) if operator.upper() == "OR" else and_(*conditions)
            )

        return query.all()

    # ──────────────────────────── utilities ───────────────────────────── #
    def _audit_fields(self, action: str) -> Dict[str, Any]:
        now = datetime.utcnow()
        user_id = self._current_user_id()
        if action == "create":
            return {"created_at": now, "created_by": user_id}
        if action in {"update", "delete", "restore"}:
            return {"updated_at": now, "updated_by": user_id}
        return {}

    @staticmethod
    def _current_user_id() -> Optional[int]:
        # Integrate with Flask‑Login or your auth solution if needed.
        return None

    @staticmethod
    def _translate_db_error(error: Exception, action: str) -> Exception:
        if isinstance(error, SQLIntegrityError):
            msg = str(error.orig).lower()
            if "unique" in msg:
                return ValueError(f"Unique constraint violated during {action}")
            if "foreign key" in msg:
                return ValueError(f"Foreign‑key constraint violated during {action}")
        return RuntimeError(f"Database error during {action}: {error}")

    # ────────────────────────── abstract api ──────────────────────────── #
    @abstractmethod
    def find_by_criteria(self, criteria: Dict[str, Any]) -> List[M]:
        """Concrete repositories must implement their preferred search pattern."""
        raise NotImplementedError
    
    def list_paginated(self, page: int = 1, per_page: int = 20, filters: dict | None = None):
        query = self.model_class.query
        if self.ENABLE_SOFT_DELETE and hasattr(self.model_class, "deleted_at"):
            query = query.filter(self.model_class.deleted_at.is_(None))
        if filters:
            for f, v in filters.items():
                if hasattr(self.model_class, f):
                    query = query.filter(getattr(self.model_class, f) == v)
        total = query.count()
        items = query.offset((page - 1) * per_page).limit(per_page).all()
        return {"items": items, "total": total, "page": page, "per_page": per_page}

    def lock_for_update(self, entity_id: int | str):
        # requer transação ativa (use @transactional no método chamador)
        stmt = select(self.model_class).where(self.model_class.id == entity_id).with_for_update()
        return self.session.execute(stmt).scalars().first()

    def count(self, **criteria):
        query = self.model_class.query
        for f, v in (criteria or {}).items():
            if hasattr(self.model_class, f):
                query = query.filter(getattr(self.model_class, f) == v)
        return query.count()
