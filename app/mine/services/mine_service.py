"""
MineService
===========

Business logic layer for Mine management with special support for 
creating mines with associated products in a single transaction.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional
from decimal import Decimal

from app.lib.services.base import BaseService
from app.mine.repository.mine_repository import (
    SQLAlchemyMineRepository,
    MineFilter,
    MineSort,
    Page,
    NotFoundError,
    DuplicateError,
)
from app.product.services.product_service import ProductService
from app.models.product import Mine
from app.extensions import db


class MineService(BaseService):
    """
    Mine business logic service.
    
    Provides high-level operations for mine management including:
    - CRUD operations with business validation
    - Special batch creation with products
    - Search and filtering
    - Business rule enforcement
    """

    def __init__(self, repository: Optional[SQLAlchemyMineRepository] = None):
        """
        Initialize MineService.
        
        Args:
            repository: Optional repository instance. If not provided,
                       creates a new one using the default session.
        """
        if repository is None:
            repository = SQLAlchemyMineRepository(db.session)
        
        super().__init__(repository)
        self.repo = repository
        self.product_service = ProductService()

    # ─────────────────────────── validation rules ────────────────────────── #
    
    def _validate_mine_data(self, data: Dict[str, Any], is_update: bool = False) -> List[str]:
        """Validate mine data according to business rules."""
        errors = []
        
        # Required fields validation (only for creation)
        if not is_update:
            required_fields = ["name", "country", "port_location", "port_latitude", "port_longitude"]
            errors.extend(self.validate_required(data, required_fields))
        
        # Field constraints validation
        constraints = {
            "name": {
                "type": str,
                "min_length": 1,
                "max_length": 200,
            },
            "code": {
                "type": str,
                "max_length": 50,
            },
            "country": {
                "type": str,
                "min_length": 1,
                "max_length": 100,
            },
            "port_location": {
                "type": str,
                "min_length": 1,
                "max_length": 150,
            },
            "port_berths": {
                "type": int,
                "min_value": 0,
            },
            "shiploaders": {
                "type": int,
                "min_value": 0,
            },
        }
        errors.extend(self.validate_constraints(data, constraints))
        
        # Coordinate validation
        if "port_latitude" in data:
            lat = data["port_latitude"]
            if lat is not None:
                try:
                    lat_decimal = Decimal(str(lat))
                    if not (-90 <= lat_decimal <= 90):
                        errors.append("Port latitude must be between -90 and 90 degrees")
                except (ValueError, TypeError):
                    errors.append("Port latitude must be a valid number")
        
        if "port_longitude" in data:
            lon = data["port_longitude"]
            if lon is not None:
                try:
                    lon_decimal = Decimal(str(lon))
                    if not (-180 <= lon_decimal <= 180):
                        errors.append("Port longitude must be between -180 and 180 degrees")
                except (ValueError, TypeError):
                    errors.append("Port longitude must be a valid number")
        
        # Business rules validation
        business_rules = [
            {
                "name": "Mine name uniqueness",
                "function": lambda d: self._validate_name_uniqueness(
                    d.get("name"), 
                    d.get("id") if is_update else None
                ),
            },
            {
                "name": "Mine code uniqueness",
                "function": lambda d: self._validate_code_uniqueness(
                    d.get("code"),
                    d.get("id") if is_update else None
                ),
            },
        ]
        errors.extend(self.validate_business_rules(data, business_rules))
        
        return errors

    def _validate_name_uniqueness(self, name: str, exclude_id: Optional[int] = None) -> tuple[bool, str]:
        """Validate that mine name is unique."""
        if not name:
            return True, ""
        
        try:
            exists = self.repo.exists_by_name(name, exclude_id=exclude_id)
            if exists:
                return False, f"Mine with name '{name}' already exists"
            return True, ""
        except Exception as e:
            return False, f"Error checking name uniqueness: {str(e)}"

    def _validate_code_uniqueness(self, code: Optional[str], exclude_id: Optional[int] = None) -> tuple[bool, str]:
        """Validate that mine code is unique."""
        if not code:
            return True, ""
        
        try:
            exists = self.repo.exists_by_code(code, exclude_id=exclude_id)
            if exists:
                return False, f"Mine with code '{code}' already exists"
            return True, ""
        except Exception as e:
            return False, f"Error checking code uniqueness: {str(e)}"

    def _validate_products_data(self, products_data: List[Dict[str, Any]]) -> List[str]:
        """Validate products data for batch creation."""
        errors = []
        
        if not products_data:
            return errors
        
        # Check for duplicate product names in the batch
        names = [p.get("name", "").strip() for p in products_data if p.get("name")]
        duplicate_names = [name for name in set(names) if names.count(name) > 1]
        if duplicate_names:
            errors.append(f"Duplicate product names in batch: {', '.join(duplicate_names)}")
        
        # Check for duplicate product codes in the batch
        codes = [p.get("code", "").strip() for p in products_data if p.get("code")]
        duplicate_codes = [code for code in set(codes) if codes.count(code) > 1]
        if duplicate_codes:
            errors.append(f"Duplicate product codes in batch: {', '.join(duplicate_codes)}")
        
        # Validate each product individually
        for i, product_data in enumerate(products_data):
            if not product_data.get("name", "").strip():
                errors.append(f"Product {i+1}: name is required")
            
            # Validate product constraints
            product_constraints = {
                "name": {"type": str, "min_length": 1, "max_length": 100},
                "code": {"type": str, "max_length": 50},
                "description": {"type": str, "max_length": 1000},
            }
            product_errors = self.validate_constraints(product_data, product_constraints)
            for error in product_errors:
                errors.append(f"Product {i+1}: {error}")
        
        return errors

    # ─────────────────────────── crud operations ──────────────────────────── #

    def create_mine(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Create a new mine.
        
        Args:
            data: Mine data dictionary
            
        Returns:
            Service response with created mine data
        """
        # Sanitize input data
        clean_data = {k: self.sanitize(v) for k, v in data.items()}
        
        # Validate data
        validation_errors = self._validate_mine_data(clean_data, is_update=False)
        if validation_errors:
            return self.validation_error(validation_errors)

        def create_operation():
            try:
                mine = self.repo.create(clean_data)
                db.session.commit()
                return mine
            except DuplicateError as e:
                db.session.rollback()
                raise ValueError(f"Duplicate mine: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to create mine: {str(e)}")

        result = self.safe_repository_operation("create", create_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        return self.ok(
            "Mine created successfully",
            data=result.to_dict(include_products=True),
            metadata={"mine_id": result.id}
        )

    def create_mine_with_products(self, mine_data: Dict[str, Any], products_data: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Create a mine with associated products in a single transaction.
        
        Args:
            mine_data: Mine data dictionary
            products_data: List of product data dictionaries
            
        Returns:
            Service response with created mine and products data
        """
        # Sanitize input data
        clean_mine_data = {k: self.sanitize(v) for k, v in mine_data.items()}
        clean_products_data = [
            {k: self.sanitize(v) for k, v in product.items()} 
            for product in products_data
        ]
        
        # Validate mine data
        mine_validation_errors = self._validate_mine_data(clean_mine_data, is_update=False)
        if mine_validation_errors:
            return self.validation_error(mine_validation_errors)
        
        # Validate products data
        products_validation_errors = self._validate_products_data(clean_products_data)
        if products_validation_errors:
            return self.validation_error(products_validation_errors)

        def create_batch_operation():
            try:
                # Create mine first
                mine = self.repo.create(clean_mine_data)
                db.session.flush()  # Get mine ID
                
                # Create products associated with the mine
                created_products = []
                for product_data in clean_products_data:
                    product_data["mine_id"] = mine.id
                    
                    # Use ProductService to create each product (leverages existing validations)
                    product_result = self.product_service.create_product(product_data)
                    if not product_result.get("success"):
                        raise ValueError(f"Failed to create product: {product_result.get('message')}")
                    
                    created_products.append(product_result["data"])
                
                # Commit the entire transaction
                db.session.commit()
                
                # Refresh mine to get updated products relationship
                db.session.refresh(mine)
                
                return {
                    "mine": mine,
                    "products": created_products,
                    "total_products": len(created_products)
                }
                
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to create mine with products: {str(e)}")

        result = self.safe_repository_operation("create_batch", create_batch_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
        
        # Format response data
        response_data = {
            "mine": result["mine"].to_dict(include_products=True),
            "products": result["products"],
            "summary": {
                "mine_id": result["mine"].id,
                "mine_name": result["mine"].name,
                "total_products_created": result["total_products"]
            }
        }
        
        return self.ok(
            f"Mine created successfully with {result['total_products']} products",
            data=response_data,
            metadata={
                "mine_id": result["mine"].id,
                "products_created": result["total_products"]
            }
        )

    def get_mine(self, mine_id: int, include_products: bool = False) -> Dict[str, Any]:
        """
        Get a mine by ID.
        
        Args:
            mine_id: Mine ID
            include_products: Whether to include products data
            
        Returns:
            Service response with mine data
        """
        cache_key = f"mine:{mine_id}:products:{include_products}"
        cached_result = self._cache_get(cache_key)
        if cached_result:
            return self.ok("Mine retrieved from cache", data=cached_result)

        def get_operation():
            mine = self.repo.get(mine_id, with_products=include_products)
            if not mine:
                raise NotFoundError(f"Mine {mine_id} not found")
            return mine

        result = self.safe_repository_operation("get", get_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        mine_data = result.to_dict(include_products=include_products)
        self._cache_set(cache_key, mine_data, timeout=300)
        
        return self.ok("Mine retrieved successfully", data=mine_data)

    def update_mine(self, mine_id: int, data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Update a mine.
        
        Args:
            mine_id: Mine ID
            data: Updated mine data
            
        Returns:
            Service response with updated mine data
        """
        # Sanitize input data
        clean_data = {k: self.sanitize(v) for k, v in data.items()}
        clean_data["id"] = mine_id  # Add ID for validation
        
        # Validate data
        validation_errors = self._validate_mine_data(clean_data, is_update=True)
        if validation_errors:
            return self.validation_error(validation_errors)

        def update_operation():
            try:
                mine = self.repo.update_fields(mine_id, clean_data)
                db.session.commit()
                return mine
            except NotFoundError as e:
                raise ValueError(f"Mine not found: {str(e)}")
            except DuplicateError as e:
                db.session.rollback()
                raise ValueError(f"Duplicate mine: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to update mine: {str(e)}")

        result = self.safe_repository_operation("update", update_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Clear related cache entries
        self.clear_cache(f"mine:{mine_id}")
        
        return self.ok(
            "Mine updated successfully",
            data=result.to_dict(include_products=True),
            metadata={"mine_id": result.id}
        )

    def delete_mine(self, mine_id: int, soft_delete: bool = True) -> Dict[str, Any]:
        """
        Delete a mine.
        
        Args:
            mine_id: Mine ID
            soft_delete: Whether to perform soft delete
            
        Returns:
            Service response
        """
        def delete_operation():
            try:
                self.repo.delete(mine_id, soft=soft_delete)
                db.session.commit()
                return True
            except NotFoundError as e:
                raise ValueError(f"Mine not found: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to delete mine: {str(e)}")

        result = self.safe_repository_operation("delete", delete_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Clear related cache entries
        self.clear_cache(f"mine:{mine_id}")
        
        delete_type = "soft deleted" if soft_delete else "permanently deleted"
        return self.ok(f"Mine {delete_type} successfully")

    def restore_mine(self, mine_id: int) -> Dict[str, Any]:
        """
        Restore a soft-deleted mine.
        
        Args:
            mine_id: Mine ID
            
        Returns:
            Service response
        """
        def restore_operation():
            try:
                self.repo.restore(mine_id)
                db.session.commit()
                return True
            except NotFoundError as e:
                raise ValueError(f"Mine not found or cannot be restored: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to restore mine: {str(e)}")

        result = self.safe_repository_operation("restore", restore_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Clear related cache entries
        self.clear_cache(f"mine:{mine_id}")
        
        return self.ok("Mine restored successfully")

    # ─────────────────────────── search and listing ───────────────────────── #

    def list_mines(
        self,
        page: int = 1,
        per_page: int = 20,
        country: Optional[str] = None,
        search_query: Optional[str] = None,
        include_deleted: bool = False,
        sort_by: str = "id",
        sort_direction: str = "asc",
        include_products: bool = False,
    ) -> Dict[str, Any]:
        """
        List mines with filtering and pagination.
        
        Args:
            page: Page number
            per_page: Items per page
            country: Filter by country
            search_query: Search in name/code/country
            include_deleted: Include soft-deleted mines
            sort_by: Sort field (id, name, country, created_at, updated_at)
            sort_direction: Sort direction (asc, desc)
            include_products: Include products data
            
        Returns:
            Service response with paginated mine list
        """
        # Create filter
        mine_filter = MineFilter(
            country=country,
            q=search_query,
            include_deleted=include_deleted,
        )
        
        # Create sort
        mine_sort = MineSort(
            field=sort_by,
            direction=sort_direction,
        )
        
        # Create cache key
        cache_key = f"mines:page:{page}:per_page:{per_page}:filter:{hash(str(mine_filter.__dict__))}:sort:{sort_by}:{sort_direction}:products:{include_products}"
        cached_result = self._cache_get(cache_key)
        if cached_result:
            return self.ok("Mines retrieved from cache", data=cached_result)

        def list_operation():
            try:
                page_result = self.repo.list(
                    flt=mine_filter,
                    sort=mine_sort,
                    page=page,
                    per_page=per_page,
                    with_products=include_products,
                )
                return page_result
            except Exception as e:
                raise RuntimeError(f"Failed to list mines: {str(e)}")

        result = self.safe_repository_operation("list", list_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Serialize page result
        page_data = {
            "items": [mine.to_dict(include_products=include_products) for mine in result.items],
            "page": result.page,
            "per_page": result.per_page,
            "total": result.total,
            "pages": result.pages,
        }
        
        self._cache_set(cache_key, page_data, timeout=60)
        
        return self.ok(
            "Mines retrieved successfully",
            data=page_data,
            metadata={
                "total_items": result.total,
                "current_page": result.page,
                "total_pages": result.pages,
            }
        )

    def search_mines(self, query: str, limit: int = 10) -> Dict[str, Any]:
        """
        Search mines by name, code, or country.
        
        Args:
            query: Search query
            limit: Maximum results
            
        Returns:
            Service response with search results
        """
        if not query or not query.strip():
            return self.error("Search query is required")
        
        return self.list_mines(
            page=1,
            per_page=limit,
            search_query=query.strip(),
            sort_by="name",
            sort_direction="asc",
        )

    def get_mines_by_country(self, country: str, include_deleted: bool = False) -> Dict[str, Any]:
        """
        Get all mines for a specific country.
        
        Args:
            country: Country name
            include_deleted: Include soft-deleted mines
            
        Returns:
            Service response with country's mines
        """
        return self.list_mines(
            page=1,
            per_page=1000,  # Large limit to get all mines
            country=country,
            include_deleted=include_deleted,
            sort_by="name",
            sort_direction="asc",
        )

    # ─────────────────────────── statistics and metrics ───────────────────── #

    def get_mine_statistics(self) -> Dict[str, Any]:
        """
        Get mine statistics.
        
        Returns:
            Service response with statistics
        """
        cache_key = "mine_statistics"
        cached_result = self._cache_get(cache_key)
        if cached_result:
            return self.ok("Statistics retrieved from cache", data=cached_result)

        def stats_operation():
            try:
                # Get total mines
                total_page = self.repo.list(page=1, per_page=1)
                total_mines = total_page.total
                
                # Get deleted mines count
                deleted_filter = MineFilter(only_deleted=True)
                deleted_page = self.repo.list(flt=deleted_filter, page=1, per_page=1)
                deleted_mines = deleted_page.total
                
                return {
                    "total_mines": total_mines,
                    "active_mines": total_mines - deleted_mines,
                    "deleted_mines": deleted_mines,
                }
            except Exception as e:
                raise RuntimeError(f"Failed to get statistics: {str(e)}")

        result = self.safe_repository_operation("statistics", stats_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        self._cache_set(cache_key, result, timeout=300)
        
        return self.ok("Statistics retrieved successfully", data=result)

