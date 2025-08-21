"""
Mine Module
===========

This module contains all mine-related functionality including:
- Models (Mine - defined in app.models.product)
- Repository layer (MineRepository)
- Service layer (MineService)
- Routes (Mine API endpoints)

Special Features:
- Create mine with products in single transaction
- Batch operations support
- Advanced filtering and search
"""

from flask import Blueprint

# Import routes and services
from app.mine.routes import mine_bp
from app.mine.services import MineService
from app.mine.repository.mine_repository import SQLAlchemyMineRepository

# Export main components
__all__ = [
    'mine_bp', 
    'MineService',
    'SQLAlchemyMineRepository'
]
