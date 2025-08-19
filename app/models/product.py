from __future__ import annotations

from decimal import Decimal
from typing import Optional, Dict, Any, List

from app.lib import BaseModel
import sqlalchemy as sa
from sqlalchemy import (
    CheckConstraint,
    UniqueConstraint,
    Numeric,
    SmallInteger,
    Index,
    ForeignKey,
    Integer,
    String,
    Text,
    func,
    select,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship, column_property

class Mine(BaseModel):
    """
    Mine Model

    Represents mining locations where bauxite is extracted.
    Each mine can produce multiple products.
    """

    __tablename__ = "mines"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)

    # ---------------------------------------------------------------------
    # Core identifiers
    # ---------------------------------------------------------------------
    name: Mapped[str] = mapped_column(
        String(200),
        nullable=False,
        unique=True,
        comment="Mine name"
    )

    code: Mapped[Optional[str]] = mapped_column(
        String(50),
        unique=True,
        nullable=True,
        comment="Mine Code (if not provided, will use name as main recognition)"
    )

    country: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
        comment="Country of the mine"
    )

    # ---------------------------------------------------------------------
    # Port information
    # ---------------------------------------------------------------------
    port_location: Mapped[str] = mapped_column(
        String(150),
        nullable=False,
        comment="Port Location"
    )

    port_latitude: Mapped[Decimal] = mapped_column(
        Numeric(9, 6),
        nullable=False,
        comment="Port Latitude"
    )

    port_longitude: Mapped[Decimal] = mapped_column(
        Numeric(9, 6),
        nullable=False,
        comment="Port Longitude"
    )

    port_berths: Mapped[int] = mapped_column(
        SmallInteger,
        nullable=False,
        default=1,
        comment="Port berths"
    )

    shiploaders: Mapped[int] = mapped_column(
        SmallInteger,
        nullable=False,
        default=1,
        comment="Port shiploaders"
    )

    # ---------------------------------------------------------------------
    # Relationships
    # ---------------------------------------------------------------------
    products: Mapped[List['Product']] = relationship(
        "Product",
        back_populates="mine",
        cascade="all, delete-orphan",
        lazy="selectin"
    ) 

    berths: Mapped[List["Berth"]] = relationship(
        "Berth",
        back_populates='mine',
        cascade='all, delete-orphan',
        lazy='selectin',
        order_by='Berth.priority'
    )

    # ---------------------------------------------------------------------
    # Table-level constraints and indexes
    # ---------------------------------------------------------------------
    __table_args__ = (
        CheckConstraint("port_latitude BETWEEN -90 AND 90", name="ck_mines_lat_range"),
        CheckConstraint("port_longitude BETWEEN -180 AND 180", name="ck_mines_lon_range"),
        CheckConstraint("port_berths >= 0", name="ck_mines_berths_nonneg"),
        CheckConstraint("port_shiploaders >= 0", name="ck_mines_shiploaders_nonneg"),
        Index('idx_mine_country', 'country'),
    )

    # ---------------------------------------------------------------------
    # Business methods
    # ---------------------------------------------------------------------
    def get_main_identifier(self) -> str:
        """
        Get the main recognition identifier for this mine.
        If mine has a code, the code will be the main recognition.
        If mine does not have a code, it will be the same as the name.
        """
        return self.code if self.code else self.name
    
    def berths_count(self) -> str:
        """Returns the amount of real berths registered."""
        return len(self.berths)
    
    def sync_port_berths_from_berths(self) -> None:
        self.port_berths = self.berths_count()
        
        
    # ---------------------------------------------------------------------
    # Validation and serialization
    # ---------------------------------------------------------------------
    def validate(self) -> List[str]:
        """Validate mine data."""
        errors = []

        if not self.name or not self.name.strip():
            errors.append("Mine name is required")

        if not self.country or not self.country.strip():
            errors.append("Country is required")

        if not self.port_location or not self.port_location.strip():
            errors.append("Port location is required")

        # Validate coordinates
        if self.port_latitude is None or not (-90 <= self.port_latitude <= 90):
            errors.append("Port latitude must be between -90 and 90 degrees")
            
        if self.port_longitude is None or not (-180 <= self.port_longitude <= 180):
            errors.append("Port longitude must be between -180 and 180 degrees")

        # Validate port facilities
        if self.port_berths < 0:
            errors.append("Port berths cannot be negative")

        if self.port_shiploaders < 0:
            errors.append("Port shiploaders cannot be negative")

        return errors

    def __repr__(self) -> str:
        return f"<Mine {self.get_main_identifier()!r}>"

    def to_dict(self, *, include_products: bool = False, include_audit: bool = True) -> Dict[str, Any]:
        """Serialize the mine to a dictionary."""
        result = super().to_dict(include_audit=include_audit)
        result['main_identifier'] = self.get_main_identifier()

        if include_products:
            result["products"] = [
                pr.to_dict(include_audit=include_audit) for pr in self.products
            ]
        else:
            result["products_count"] = self.products_count

        return result


class Product(BaseModel):
    """
    Product Model

    Represents a bauxite product produced by a mine.
    Two products can have the same name but from different mines,
    and they are not intended to be the same product.
    """

    __tablename__ = "products"

    id:Mapped[int] = mapped_column(Integer, primary_key=True)

    # ---------------------------------------------------------------------
    # Core identifiers
    # ---------------------------------------------------------------------
    name: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
        comment="Name of the product"
    )

    code: Mapped[Optional[str]] = mapped_column(
        String(50),
        unique=True,
        nullable=True,
        comment="Code of the product (globally unique if provided)"
    )

    description: Mapped[Optional[str]] = mapped_column(
        Text,
        comment="Description"
    )

    # ---------------------------------------------------------------------
    # Foreign key to Mine
    # ---------------------------------------------------------------------
    mine_id: Mapped[int] = mapped_column(
        Integer,
        ForeignKey("mines.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
        comment="Mine related to the product"
    )

    mine = relationship(
        "Mine", 
        back_populates="products",
        lazy="selectin"    
    )

    # ---------------------------------------------------------------------
    # Table-level constraints and indexes
    # ---------------------------------------------------------------------
    __table_args__ = (
        # Products can have same name but different mines (no unique constraint on name alone)
        # Only code needs to be globally unique (handled by unique=True on code column)
        UniqueConstraint('mine_id', 'name', name='uq_product_mine_name'),
        Index('idx_product_mine', 'mine_id'),
        Index('idx_product_name', 'name'),
    )

    # ---------------------------------------------------------------------
    # Validation and serialization
    # ---------------------------------------------------------------------
    def validate(self) -> List[str]:
        """Validate product data."""
        errors = []

        if not self.name or not self.name.strip():
            errors.append("Product name is required")

        if not self.mine_id:
            errors.append("Product must be associated with a mine")

        return errors

    def __repr__(self) -> str:
        product_identifier = self.code or self.name
        mine_label = getattr(self, "mine", None)
        mine_identifier = mine_label.get_main_identifier() if mine_label else self.mine_id
        return f"<Product {product_identifier!r} (Mine: {mine_identifier})>"

    def to_dict(self, deep: bool = False, include: set | None = None, exclude: set | None = None) -> dict:
        """
        Serialize product for API/UI usage.
        - deep=False: lean (id, code, name, type, mine ref)
        - deep=True or include 'mine': expand mine shallow
        """
        include = set(include or [])
        exclude = set(exclude or [])
    
        def ref(obj, label: str = "name"):
            if obj is None:
                return None
            return {"id": getattr(obj, "id", None), label: getattr(obj, label, None)}
    
        data = super().to_dict(include=include, exclude=exclude)
    
        # Normalize core fields
        data.update({
            "code": getattr(self, "code", None),
            "name": getattr(self, "name", None),
            "type": getattr(self, "type", None) if hasattr(self, "type") else None,
        })
    
        # Always provide mine as shallow ref (unless excluded)
        if "mine" not in exclude:
            mine = getattr(self, "mine", None)
            data["mine"] = ref(mine)
    
        # Optionally expand related stuff
        if deep or ("mine" in include):
            # If you want more mine details in some contexts
            mine = getattr(self, "mine", None)
            if mine:
                data["mine"] = {
                    "id": mine.id,
                    "name": getattr(mine, "name", None),
                    "code": getattr(mine, "code", None),
                    "country": getattr(mine, "country", None),
                }
    
        return data
    
Mine.products_count = column_property(
    select(func.count(Product.id))
    .where(Product.mine_id == Mine.id)
    .correlate_except(Product)
    .scalar_subquery()
)

