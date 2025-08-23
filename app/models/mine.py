from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, Optional

from sqlalchemy import Integer, String, Float, Boolean, Index
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.extensions import db
from app.lib.base_model import BaseModel


class Mine(BaseModel):
    """
    Mining site (origin).
    Soft-deletable via BaseModel.deleted_at.
    """

    __tablename__ = "mines"
    __mapper_args__ = {"eager_defaults": True}

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    # Business fields
    name: Mapped[str] = mapped_column(String(120), nullable=False, index=True, unique=True)
    code: Mapped[Optional[str]] = mapped_column(String(24), nullable=True, unique=True)
    country: Mapped[Optional[str]] = mapped_column(String(80), nullable=True, index=True)
    state: Mapped[Optional[str]] = mapped_column(String(80), nullable=True)
    city: Mapped[Optional[str]] = mapped_column(String(80), nullable=True)

    latitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    longitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True)

    berths: Mapped[int] = mapped_column(Integer, nullable=False, default=1)        # terminal berths
    shiploaders: Mapped[int] = mapped_column(Integer, nullable=False, default=1)   # available shiploaders
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    # Relationships
    products = relationship("Product", back_populates="mine", lazy="select")

    __table_args__ = (
        Index("ix_mines_name_country", "name", "country"),
    )

    # ----------------------- helpers -----------------------
    def __repr__(self) -> str:  # pragma: no cover
        return f"<Mine id={self.id} name={self.name!r}>"

    def to_dict(
        self,
        deep: bool = False,
        include: set | None = None,
        exclude: set | None = None,
        include_products: bool = False,
    ) -> Dict[str, Any]:
        data = super().to_dict(deep=deep, include=include, exclude=exclude)
        if include_products:
            data["products"] = [
                {"id": p.id, "name": getattr(p, "name", None)}
                for p in (self.products or [])
            ]
        return data
