"""
Base Model with Audit Fields
============================

Provides a base model class that includes common audit fields
for tracking creation, modification, and soft deletion.

All application models should inherit from this base class to
ensure consistent audit trail across the system.
"""

from datetime import datetime
from typing import Dict, Any, Optional
from app.extensions import db


class BaseModel(db.Model):
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
    
    def to_dict(self, include_audit: bool = True) -> Dict[str, Any]:
        """
        Convert model instance to dictionary.
        
        Args:
            include_audit: Whether to include audit fields in the output
            
        Returns:
            Dictionary representation of the model
        """
        result = {}
        
        # Get all columns except audit fields initially
        for column in self.__table__.columns:
            if not include_audit and column.name in {
                'created_at', 'updated_at', 'created_by', 
                'updated_by', 'deleted_at', 'deleted_by'
            }:
                continue
                
            value = getattr(self, column.name)
            
            # Handle datetime serialization
            if isinstance(value, datetime):
                result[column.name] = value.isoformat()
            else:
                result[column.name] = value
                
        return result
    
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