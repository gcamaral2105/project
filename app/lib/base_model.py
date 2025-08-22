"""
Base Model with Audit Fields
============================

Provides a base model class that includes common audit fields
for tracking creation, modification, and soft deletion.

All application models should inherit from this base class to
ensure consistent audit trail across the system.
"""

from __future__ import annotations
from datetime import datetime
from typing import Dict, Any, Optional, Iterable, Set
from app.extensions import db

from sqlalchemy.orm import DeclarativeBase, inspect as sa_inspect

class Base(DeclarativeBase):
    pass

class BaseModel(Base):
    """
    Abstract base model with audit fields.
    
    Provides common fields for tracking:
    - Creation timestamp and user
    - Last modification timestamp and user  
    - Soft deletion timestamp and user
    
    All concrete models should inherit from this class.
    """
    
    __abstract__ = True
    
    # Primary audit fields
    created_at = db.Column(
        db.DateTime, 
        default=datetime.utcnow, 
        nullable=False,
        comment="Timestamp when the record was created"
    )
    
    updated_at = db.Column(
        db.DateTime, 
        default=datetime.utcnow, 
        onupdate=datetime.utcnow,
        nullable=False,
        comment="Timestamp when the record was last updated"
    )
    
    created_by = db.Column(
        db.Integer, 
        # db.ForeignKey('users.id'),  # Uncomment when User model is available
        nullable=True,  # Allow null for now until User model is implemented
        comment="ID of the user who created this record"
    )
    
    updated_by = db.Column(
        db.Integer,
        # db.ForeignKey('users.id'),  # Uncomment when User model is available
        nullable=True,  # Allow null for now until User model is implemented
        comment="ID of the user who last updated this record"
    )
    
    # Soft delete support
    deleted_at = db.Column(
        db.DateTime,
        nullable=True,
        comment="Timestamp when the record was soft deleted (null if active)"
    )
    
    deleted_by = db.Column(
        db.Integer,
        # db.ForeignKey('users.id'),  # Uncomment when User model is available
        nullable=True,
        comment="ID of the user who soft deleted this record"
    )
    
    def to_dict(
        self,
        deep: bool = False,
        include: Iterable[str] | None = None,
        exclude: Iterable[str] | None = None,
    ) -> dict[str, Any]:
        """
        Serializa colunas e (opcionalmente) relações.
        - include/exclude: nomes de atributos (colunas/props)
        - deep=True: carrega relações 1..N/N..1 superficialmente (evita recursão)
        """
        include = set(include or [])
        exclude: Set[str] = set(exclude or [])
        mapper = sa_inspect(self.__class__)
        data: dict[str, Any] = {}

        # colunas simples
        for col in mapper.columns:
            name = col.key
            if include and name not in include:
                continue
            if name in exclude:
                continue
            data[name] = getattr(self, name)

        # propriedades híbridas (@hybrid_property) e synonyms opcionais
        for prop in getattr(mapper, "all_orm_descriptors", []):
            name = getattr(prop, "__name__", None)
            if not name or name in data:
                continue
            if include and name not in include:
                continue
            if name in exclude:
                continue
            try:
                value = getattr(self, name)
            except Exception:
                continue
            if callable(value):
                continue
            # valores simples apenas
            if isinstance(value, (str, int, float, bool)) or value is None:
                data[name] = value

        # relações (shallow por padrão; deep expande listas como refs compactas)
        if deep:
            for rel in mapper.relationships:
                name = rel.key
                if include and name not in include:
                    continue
                if name in exclude:
                    continue
                value = getattr(self, name)
                if value is None:
                    data[name] = None
                elif rel.uselist:
                    data[name] = [self._ref(item) for item in value]
                else:
                    data[name] = self._ref(value)

        # normalização datetimes -> isoformat
        for k in ("created_at", "updated_at"):
            if k in data and isinstance(data[k], datetime):
                data[k] = data[k].isoformat()

        return data

    @staticmethod
    def _ref(obj: Any, label: str = "name") -> dict[str, Any] | None:
        if obj is None:
            return None
        obj_id = getattr(obj, "id", None)
        label_val = getattr(obj, label, None) if hasattr(obj, label) else None
        return {"id": obj_id, label: label_val}
    
    
    def is_deleted(self) -> bool:
        """Check if this record is soft deleted."""
        return self.deleted_at is not None
    
    def mark_deleted(self, user_id: Optional[int] = None) -> None:
        """
        Mark this record as soft deleted.
        
        Args:
            user_id: ID of the user performing the deletion
        """
        self.deleted_at = datetime.utcnow()
        if user_id:
            self.deleted_by = user_id
    
    def restore(self, user_id: Optional[int] = None) -> None:
        """
        Restore a soft deleted record.
        
        Args:
            user_id: ID of the user performing the restoration
        """
        self.deleted_at = None
        self.deleted_by = None
        self.updated_at = datetime.utcnow()
        if user_id:
            self.updated_by = user_id
    
    def update_audit_fields(self, user_id: Optional[int] = None) -> None:
        """
        Update audit fields for modification tracking.
        
        Args:
            user_id: ID of the user making the changes
        """
        self.updated_at = datetime.utcnow()
        if user_id:
            self.updated_by = user_id
    
    def __repr__(self) -> str:
        """Default string representation showing ID and creation time."""
        return f"<{self.__class__.__name__} id={getattr(self, 'id', 'None')} created_at={self.created_at}>"
