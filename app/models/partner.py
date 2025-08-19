from __future__ import annotations

from app.lib import BaseModel
from typing import Optional, Dict, Any, List
import sqlalchemy as sa
from sqlalchemy import (
    CheckConstraint,
    UniqueConstraint,
    Boolean,
    Index,
    ForeignKey,
    Integer,
    String,
    Text,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship, column_property


class PartnerEntity(BaseModel):
    """
    Partner Entity Model
    
    Represents a buyer entity in the bauxite supply chain.
    An entity can be either a Halco buyer or not, and can have
    multiple partners (clients) associated with it.
    """

    __tablename__ = 'partner_entities'

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    
    # ---------------------------------------------------------------------
    # Core fields
    # ---------------------------------------------------------------------
    name: Mapped[str] = mapped_column(
        String(100), 
        nullable=False,
        comment="Name of the entity"
    )
    
    code: Mapped[str] = mapped_column(
        String(20), 
        unique=True, 
        nullable=False,
        comment="Code of the entity"
    )
    
    description: Mapped[Optional[str]] = mapped_column(
        Text,
        comment="Description"
    )

    is_halco_buyer: Mapped[bool] = mapped_column(
        Boolean,
        default=False,
        nullable=False,
        comment="If is Halco Buyer or not"
    )

    # ---------------------------------------------------------------------
    # Relationships
    # ---------------------------------------------------------------------
    partners = relationship(
        'Partner', 
        back_populates='entity', 
        lazy='selectin', 
        cascade='all, delete-orphan',
        passive_deletes=True
    )
    
    # ---------------------------------------------------------------------
    # Table constraints and indexes
    # ---------------------------------------------------------------------
    __table_args__ = (
        Index('idx_entity_halco', 'is_halco_buyer'),
    )

    # ---------------------------------------------------------------------
    # Validation and serialization
    # ---------------------------------------------------------------------
    def validate(self) -> List[str]:
        """Validate the partner entity data."""
        errors = []
        
        if not self.name or not self.name.strip():
            errors.append("Entity name is required")
            
        if not self.code or not self.code.strip():
            errors.append("Entity code is required")
            
        if len(self.name) > 100:
            errors.append("Entity name must be 100 characters or less")
            
        if len(self.code) > 20:
            errors.append("Entity code must be 20 characters or less")
            
        return errors

    def __repr__(self) -> str:
        buyer_type = "Halco Buyer" if self.is_halco_buyer else "Offtaker"
        return f'<PartnerEntity {self.name} ({buyer_type})>'
    
    @classmethod
    def get_halco_buyers(cls):
        """Get all Halco buyers entities."""
        return cls.query.filter_by(is_halco_buyer=True).all()
    
    @classmethod
    def get_offtakers(cls):
        """Get all offtakers entities."""
        return cls.query.filter_by(is_halco_buyer=False).all()
    
    def to_dict(self, include_partners: bool = False, include_audit: bool = True) -> Dict[str, Any]:
        """Convert to dictionary with optional partner inclusion."""
        result = super().to_dict(include_audit=include_audit)
        result['partners_count'] = self.partners_count
        
        if include_partners:
            result['partners'] = [p.to_dict(include_audit=include_audit) for p in self.partners]
            
        return result


class Partner(BaseModel):
    """
    Partner Model
    
    Represents a specific client within a partner entity.
    Each partner belongs to an entity and has minimum contractual tonnage.
    """

    __tablename__ = 'partners'

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    
    # ---------------------------------------------------------------------
    # Core fields
    # ---------------------------------------------------------------------
    name: Mapped[str] = mapped_column(
        String(100), 
        nullable=False,
        comment="Name of the partner"
    )
    
    code: Mapped[str] = mapped_column(
        String(20), 
        unique=True, 
        nullable=False,
        comment="Code of the partner"
    )
    
    description: Mapped[Optional[str]] = mapped_column(
        Text,
        comment="Description"
    )

    minimum_contractual_tonnage: Mapped[Optional[int]] = mapped_column(
        Integer,
        comment="Minimum contractual tonnage (flexible, can change every contractual year)"
    )

    # ---------------------------------------------------------------------
    # Foreign key to parent entity
    # ---------------------------------------------------------------------
    entity_id: Mapped[int] = mapped_column(
        Integer, 
        ForeignKey('partner_entities.id', ondelete='CASCADE'), 
        nullable=False,
        index=True,
        comment="Which entity belongs this partner"
    )

    # ---------------------------------------------------------------------
    # Relationships
    # ---------------------------------------------------------------------

    entity = relationship('PartnerEntity', back_populates='partners', lazy='selectin')

    enrollments: Mapped[List['ProductionPartnerEnrollment']] = relationship(
        'ProductionPartnerEnrollment',
        back_populates='partner',
        passive_deletes=True
    )
    
    # ---------------------------------------------------------------------
    # Table constraints and indexes
    # ---------------------------------------------------------------------
    __table_args__ = (
        Index('idx_partner_entity', 'entity_id'),
        UniqueConstraint("entity_id", "name", name="uq_partner_entity_name"),
        CheckConstraint(
            "minimum_contractual_tonnage IS NULL OR minimum_contractual_tonnage >= 0",
            name="ck_partner_tonnage_nonneg",
        ),
    )

    # ---------------------------------------------------------------------
    # Validation and serialization
    # ---------------------------------------------------------------------
    def validate(self) -> List[str]:
        """Validate the partner data."""
        errors = []
        
        if not self.name or not self.name.strip():
            errors.append("Partner name is required")
            
        if not self.code or not self.code.strip():
            errors.append("Partner code is required")
            
        if not self.entity_id:
            errors.append("Partner must be associated with an entity")
            
        if len(self.name) > 100:
            errors.append("Partner name must be 100 characters or less")
            
        if len(self.code) > 20:
            errors.append("Partner code must be 20 characters or less")
            
        if self.minimum_contractual_tonnage is not None and self.minimum_contractual_tonnage < 0:
            errors.append("Minimum contractual tonnage cannot be negative")
            
        return errors

    def __repr__(self) -> str:
        entity_name = getattr(self.entity, "name", None)
        return f'<Partner {self.name!r} (Entity: {entity_name})>'
    
    @property
    def is_halco_buyer(self):
        """Check if partner belongs to Halco buyer entity."""
        return self.entity.is_halco_buyer if self.entity else False
    
    def to_dict(self, include_entity: bool = True, include_audit: bool = True) -> Dict[str, Any]:
        """Convert to dictionary with optional entity details."""
        result = super().to_dict(include_audit=include_audit)
        
        if include_entity and self.entity:
            result['entity_name'] = self.entity.name
            result['entity_code'] = self.entity.code
            result['is_halco_buyer'] = self.entity.is_halco_buyer
            
        return result
    
PartnerEntity.partners_count = column_property(
    sa.select(func.count(Partner.id))
    .where(Partner.entity_id == PartnerEntity.id)
    .correlate_except(Partner)
    .scalar_subquery()
)