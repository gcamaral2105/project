"""
Product Module
==============

This module contains all product-related functionality including:
- Models (Product)
- Repository layer (ProductRepository)
- Service layer (ProductService)
- Routes (Product API endpoints)
"""

from flask import Blueprint

# Legacy blueprint (keeping for compatibility)
mine_bp = Blueprint('mine_bp', __name__,
                    template_folder='templates',
                    static_folder='static')

# Import routes and services
from app.product.routes import product_bp
from app.product.services import ProductService
from app.product.repository.product_repository import SQLAlchemyProductRepository

# Export main components
__all__ = [
    'mine_bp',
    'product_bp', 
    'ProductService',
    'SQLAlchemyProductRepository'
]

# Legacy import (keeping for compatibility)
from app.product import routes
