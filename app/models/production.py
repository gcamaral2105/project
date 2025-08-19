from __future__ import annotations

from decimal import Decimal
from typing import Optional, Dict, Any, List, TYPE_CHECKING

from app.lib import BaseModel

from enum import Enum
from datetime import datetime, date

from sqlalchemy import (
    CheckConstraint,
    UniqueConstraint,
    Index,
    Boolean,
    Date,
    DateTime,
    Enum as SQLEnum,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    text
)
from sqlalchemy.orm import Mapped, mapped_column, relationship, validates, object_session, Session
from sqlalchemy.ext.declarative import declarative_base
from datetime import datetime, date, timedelta
import json

class ProductionStatus(str, Enum):
    DRAFT = 'draft'
    PLANNED = 'planned'
    ACTIVE = 'active'
    COMPLETED = 'completed'
    ARCHIVED = 'archived'

class Production(BaseModel):
    """Production planning model with scenario management."""
    
    __tablename__='productions'
    __mapper_args__={"eager_defaults": True}
    
    id: Mapped[int] = mapped_column(Integer, primary_key=True)

    # ---------------------------------------------------------------------
    # Core fields
    # ---------------------------------------------------------------------
    scenario_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
        comment='Name of the scenario'
    )
    
    scenario_description: Mapped[Optional[str]] = mapped_column(
        Text,
        nullable=True, 
        comment='Description'
    )
    
    contractual_year: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        comment='Contractual Year'
    )
    
    total_planned_tonnage: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        comment='Total Tonnage planned (3% moisture)'
    )
    
    start_date_contractual_year: Mapped[date] = mapped_column(
        Date,
        nullable=False,
        comment='Start Date of Contractual Year'
    )
    
    end_date_contractual_year: Mapped[date] = mapped_column(
        Date,
        nullable=False,
        comment='End Date of Contractual Year'
    )
    
    standard_moisture_content: Mapped[Decimal] = mapped_column(
        Numeric(5,2),
        nullable=False,
        default=Decimal('3.00'),
        server_default=text("3.00"),
        comment='Moisture basis'
    )
    
    # ---------------------------------------------------------------------
    # Status Management
    # ---------------------------------------------------------------------
    status: Mapped[ProductionStatus] = mapped_column(
        SQLEnum(ProductionStatus, name='production_status', native_enum=True, create_constraint=True, validate_strings=True),
        nullable=False,
        default=ProductionStatus.DRAFT,
        server_default=text("'draft'"),
        comment='Scenario Status'
    )
    
    base_scenario_id: Mapped[Optional[int]] = mapped_column(
        Integer,
        ForeignKey('productions.id', ondelete='SET NULL'),
        nullable=True,
        comment='Original Scenario ID'
    )
    
    version: Mapped[int] = mapped_column(
        Integer,
        default=1,
        server_default=text("1"),
        nullable=False
    )
    
    # ---------------------------------------------------------------------
    # Lifecycle Timestamps
    # ---------------------------------------------------------------------
    activated_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True),
        server_default=None,
        nullable=True
    )
    
    completed_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True),
        nullable=True
    )
    
    # ---------------------------------------------------------------------
    # Relationships
    # ---------------------------------------------------------------------
    enrolled_partners: Mapped[List['ProductionPartnerEnrollment']] = relationship(
        'ProductionPartnerEnrollment',
        back_populates='production', 
        cascade='all, delete-orphan', 
        single_parent=True, 
        passive_deletes=True,
        lazy="selectin"
    )
    
    base_scenario: Mapped[Optional['Production']] = relationship(
        'Production', 
        remote_side='Production.id', 
        backref='derived_scenarios')
    
    # ---------------------------------------------------------------------
    # Index and Constraints
    # ---------------------------------------------------------------------
    __table_args__ = (
        Index('idx_production_contractual_year', 'contractual_year'),
        Index('idx_production_year_status', 'contractual_year', 'status'),
        Index('uq_one_active_per_year', "contractual_year", unique=True, sqlite_where=(status == ProductionStatus.ACTIVE)),
        UniqueConstraint('contractual_year', 'scenario_name', 'version', name='uq_prod_year_name_version'),
        CheckConstraint('contractual_year BETWEEN 2000 AND 2100', name='check_contractual_year_range'),
        CheckConstraint('total_planned_tonnage > 0', name='check_total_planned_tonnage_positive'),
        CheckConstraint('standard_moisture_content BETWEEN 0 AND 100', name='check_moisture_content_range'),
        CheckConstraint('start_date_contractual_year < end_date_contractual_year', name='check_date_order')
    )
    
    def __repr__(self) -> str:
        return f'<Production "{self.scenario_name}" - {self.contractual_year} ({self.status.value})>'
    
    @validates("status")
    def _validate_single_active_per_year(self, key, value):
        """Checks when it is active"""
        if value == ProductionStatus.ACTIVE:
            sess = object_session(self)
            if sess is None:
                return value
            
            q = (
                sess.query(type(self))
                .filter(
                    type(self).contractual_year == self.contractual_year,
                    type(self).status == ProductionStatus.ACTIVE
                )
            )
            if self.id is not None:
                q = q.filter(type(self).id != self.id)
                
            if sess.query(q.exists()).scalar():
                raise ValueError(
                    f"There is already an ACTIVE scenario for the year {self.contractual_year}."
                )
        
        return value
    
    @property
    def duration_days(self) -> int:
        """Calculate duration of contractual year in days."""
        return (self.end_date_contractual_year - self.start_date_contractual_year).days +1

        
    def enrolled_partners_count(self) -> int:
        """Counts enrolled partners without forcing a full load of the relationship."""
        # se a relação já estiver no estado 'loaded', use len() — é O(1)
        if 'enrolled_partners' in self.__dict__:
            return len(self.enrolled_partners)

        sess = object_session(self)
        if sess is None:
            # fallback: se não estiver anexado, usar o que houver em memória
            return len(getattr(self, 'enrolled_partners', []) or [])
        # consulta leve com COUNT(*)
        from app.models.production import ProductionPartnerEnrollment  # import local p/ evitar circular
        return (
            sess.query(ProductionPartnerEnrollment)
            .filter(ProductionPartnerEnrollment.production_id == self.id)
            .count()
        )
        
    def get_enrolled_halco_buyers(self, session: 'Session') -> List['Partner']:
        """
        Returns partners enrolled in this production whose entity_type is HALCO.
        Works with either Partner.entity_type or Partner.entity.entity_type.
        """
        from app.models.partner import Partner, PartnerEntity
        from app.models.production import ProductionPartnerEnrollment as PPE

        return (
            session.query(Partner)
            .join(PPE, PPE.partner_id == Partner.id)
            .join(PartnerEntity, Partner.entity_id == PartnerEntity.id)
            .filter(PPE.production_id == self.id, PartnerEntity.is_halco_buyer.is_(True))
        ).all()
    
    def get_enrolled_offtakers(self, session: 'Session') -> List['Partner']:
        """
        Returns partners enrolled in this production whose entity_type is OFFTAKER.
        """
        from app.models.partner import Partner, PartnerEntity
        from app.models.production import ProductionPartnerEnrollment as PPE

        return (
            session.query(Partner)
            .join(PPE, PPE.partner_id == Partner.id)
            .join(PartnerEntity, Partner.entity_id == PartnerEntity.id)
            .filter(PPE.production_id == self.id, PartnerEntity.is_halco_buyer.is_(False))
        ).all()
    
    @classmethod
    def get_current_active(cls, session: 'Session', year: Optional[int] = None) -> Optional['Production']:
        """
        Returns the ACTIVE production for the given year (defaults to today's year).
        Enforced by the partial unique index: at most one row can match.
        """
        y = year or date.today().year
        return (
            session.query(cls)
            .filter(cls.contractual_year == y, cls.status == ProductionStatus.ACTIVE)
            .one_or_none()
        )
        
    @classmethod
    def get_finalized_previous_years(cls, session: 'Session', up_to_year: Optional[int] = None) -> List['Production']:
        """
        Returns COMPLETED productions for years strictly less than up_to_year (defaults to today.year).
        """
        cutoff = up_to_year or date.today().year
        return (
            session.query(cls)
            .filter(cls.contractual_year < cutoff, cls.status == ProductionStatus.COMPLETED)
            .order_by(cls.contractual_year.desc(), cls.scenario_name.asc(), cls.version.desc())
            .all()
        )
    
    def to_dict(self, deep: bool = False, include: set | None = None, exclude: set | None = None) -> dict:
        include = set(include or [])
        exclude = set(exclude or [])
    
        def ref(obj, label: str = "name"):
            if obj is None:
                return None
            return {"id": getattr(obj, "id", None), label: getattr(obj, label, None)}
    
        data = super().to_dict(include=include, exclude=exclude)
    
        data.update({
            "status": getattr(self, "status", None).value if getattr(self, "status", None) else None,
            "period_start": getattr(self, "period_start", None),
            "period_end": getattr(self, "period_end", None),
            "mine": ref(getattr(self, "mine", None)),
        })
    
        enrollments = list(getattr(self, "enrolled_partners", []) or [])
    
        # Helper to compute planned_tonnage consistently with PPE.to_dict
        def planned_tonnage_for(e) -> int:
            incentive = e.manual_incentive_tonnage if e.manual_incentive_tonnage is not None else (e.calculated_incentive_tonnage or 0)
            return e.adjusted_tonnage if e.adjusted_tonnage is not None else (e.minimum_tonnage + incentive)
    
        total_planned = sum(planned_tonnage_for(e) for e in enrollments)
        total_actual = sum((e.calculated_vld_total_tonnage or 0) for e in enrollments)
        total_variance = sum((e.vld_tonnage_variance or ( (e.calculated_vld_total_tonnage or 0) - planned_tonnage_for(e) )) for e in enrollments)
    
        data["enrollment_summary"] = {
            "partners_count": len(enrollments),
            "total_planned_tonnage": total_planned,
            "total_actual_vld_tonnage": total_actual,
            "total_vld_variance": total_variance,
        }
    
        need_enrollments = deep or ("enrolled_partners" in include)
        if need_enrollments:
            # Expand each enrollment (and include vld_count from the model)
            expanded = []
            for e in enrollments:
                ed = e.to_dict(deep=False, include={"partner"})
                # Ensure share calculated against planned total (avoid division by zero)
                planned = ed.get("planned_tonnage", planned_tonnage_for(e))
                share = float(planned / total_planned) if total_planned else 0.0
                ed["share"] = share
                # vld_count is already in ed via PPE.to_dict, but guarantee presence
                ed["vld_count"] = ed.get("vld_count", e.calculated_vld_count or 0)
                expanded.append(ed)
            data["enrolled_partners"] = expanded
    
        return data
        
class ProductionPartnerEnrollment(BaseModel):
    """Association model for production partner enrollment with vessel sizes and tonnage."""
    
    __tablename__ = 'production_partner_enrollment'
    __mapper_args__ = {"eager_defaults": True}
    
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    
    # ---------------------------------------------------------------------
    # Foreign Keys
    # ---------------------------------------------------------------------
    production_id: Mapped[int] = mapped_column(
        Integer,
        ForeignKey('productions.id', ondelete='CASCADE'),
        nullable=False,
        index=True
    )
    
    partner_id: Mapped[int] = mapped_column(
        Integer,
        ForeignKey('partners.id', ondelete='RESTRICT'),
        nullable=False,
        index=True
    )
    
    # ---------------------------------------------------------------------
    # Vessel and Tonnage Information
    # ---------------------------------------------------------------------
    vessel_size_t: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        comment="Vessel Lot Size in 3% moisture"
    )
    
    minimum_tonnage: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        comment="Minimum Tonnage in 3% moisture"
    )
    
    adjusted_tonnage: Mapped[int] = mapped_column(
        Integer,
        nullable=True
    )
    
    manual_incentive_tonnage: Mapped[int] = mapped_column(
        Integer,
        nullable=True,
        comment="When the incentive tonnage is inserted manually"
    )
    
    calculated_incentive_tonnage: Mapped[int] = mapped_column(
        Integer,
        nullable=True,
        comment="When the incentive tonnage is inserted automatically"
    )
    
    # ---------------------------------------------------------------------
    # VLD Calculations
    # ---------------------------------------------------------------------
    calculated_vld_count: Mapped[int] = mapped_column(
        Integer,
        server_default=text("0"),
        nullable=False
    )
    
    calculated_vld_total_tonnage: Mapped[int] = mapped_column(
        Integer,
        server_default=text("0"),
        nullable=False
    )
    
    vld_tonnage_variance: Mapped[int] = mapped_column(
        Integer,
        server_default=text("0"),
        nullable=False
    )
    
    # ---------------------------------------------------------------------
    # Relationships
    # ---------------------------------------------------------------------
    production: Mapped['Production'] = relationship(
        'Production',
        back_populates='enrolled_partners',
        passive_deletes=True,
    )
    
    partner: Mapped['Partner'] = relationship(
        'Partner',
        back_populates='enrollments'
    )
    
    # ---------------------------------------------------------------------
    # Indexes and Constraints
    # ---------------------------------------------------------------------
    __table_args__ = (
        Index('idx_partner', 'partner_id'),
        UniqueConstraint('production_id', 'partner_id', name='uq_prod_partner'),
        CheckConstraint('vessel_size_t > 0', name='check_vessel_size_positive'),
        CheckConstraint('minimum_tonnage >= 0', name='check_min_tonnage_nonneg'),
        CheckConstraint('adjusted_tonnage IS NULL OR adjusted_tonnage >= 0', name='check_adjusted_tonnage_nonneg'),
        CheckConstraint('manual_incentive_tonnage IS NULL OR manual_incentive_tonnage >= 0', name='check_manual_incentive_nonneg'),
        CheckConstraint(
            'NOT (manual_incentive_tonnage IS NOT NULL AND calculated_incentive_tonnage IS NOT NULL)',
            name='check_incentive_manual_xor_calc'
        ),
    )
    
    @property
    def incentive_tonnage(self) -> int:
        return (
            self.manual_incentive_tonnage
            if self.manual_incentive_tonnage is not None
            else (self.calculated_incentive_tonnage or 0)
        )
        
    def __repr__(self) -> str:
        return f'<PPE id={self.id} prod={self.production_id} partner={self.partner_id} lot={self.vessel_size_t}>'


    def to_dict(self, deep: bool = False, include: set | None = None, exclude: set | None = None) -> dict:
        include = set(include or [])
        exclude = set(exclude or [])
    
        def ref(obj, label: str = "name"):
            if obj is None:
                return None
            return {"id": getattr(obj, "id", None), label: getattr(obj, label, None)}
    
        data = super().to_dict(include=include, exclude=exclude)
    
        # Partner (shallow)
        if "partner" not in exclude:
            data["partner"] = ref(getattr(self, "partner", None))
    
        # Incentive chosen (manual has priority)
        incentive = (
            self.manual_incentive_tonnage
            if self.manual_incentive_tonnage is not None
            else (self.calculated_incentive_tonnage or 0)
        )
    
        # Planned tonnage rule
        planned_tonnage = (
            self.adjusted_tonnage
            if self.adjusted_tonnage is not None
            else (self.minimum_tonnage + incentive)
        )
    
        # Actuals from VLD aggregates already on the model
        actual_vld_count = self.calculated_vld_count or 0
        actual_vld_tonnage = self.calculated_vld_total_tonnage or 0
    
        # Variance (use stored field if you keep it updated, else recompute)
        variance = (
            self.vld_tonnage_variance
            if self.vld_tonnage_variance is not None
            else actual_vld_tonnage - planned_tonnage
        )
    
        data.update({
            "vessel_size_t": self.vessel_size_t,
            "minimum_tonnage": self.minimum_tonnage,
            "adjusted_tonnage": self.adjusted_tonnage,
            "incentive_tonnage": incentive,
            "planned_tonnage": planned_tonnage,
            "vld_count": actual_vld_count,
            "vld_total_tonnage": actual_vld_tonnage,
            "vld_tonnage_variance": variance,
            "production_id": self.production_id,
            "partner_id": self.partner_id,
        })
    
        return data
