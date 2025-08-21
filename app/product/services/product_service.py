"""
ProductService
==============

Business logic layer for Product management.
Integrates with ProductRepository and provides high-level operations
with validation, caching, and business rules.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from app.lib.services.base import BaseService
from app.product.repository.product_repository import (
    SQLAlchemyProductRepository,
    ProductFilter,
    ProductSort,
    Page,
    NotFoundError,
    DuplicateError,
)
from app.models.product import Product
from app.extensions import db


class ProductService(BaseService):
    """
    Product business logic service.
    
    Provides high-level operations for product management including:
    - CRUD operations with business validation
    - Search and filtering
    - Business rule enforcement
    - Integration with caching and metrics
    """

    def __init__(self, repository: Optional[SQLAlchemyProductRepository] = None):
        """
        Initialize ProductService.
        
        Args:
            repository: Optional repository instance. If not provided,
                       creates a new one using the default session.
        """
        if repository is None:
            repository = SQLAlchemyProductRepository(db.session)
        
        super().__init__(repository)
        self.repo = repository

    # ─────────────────────────── validation rules ────────────────────────── #
    
    def _validate_product_data(self, data: Dict[str, Any], is_update: bool = False) -> List[str]:
        """Validate product data according to business rules."""
        errors = []
        
        # Required fields validation (only for creation)
        if not is_update:
            required_fields = ["name", "mine_id"]
            errors.extend(self.validate_required(data, required_fields))
        
        # Field constraints validation
        constraints = {
            "name": {
                "type": str,
                "min_length": 1,
                "max_length": 100,
            },
            "code": {
                "type": str,
                "max_length": 50,
            },
            "description": {
                "type": str,
                "max_length": 1000,
            },
            "mine_id": {
                "type": int,
                "min_value": 1,
            },
        }
        errors.extend(self.validate_constraints(data, constraints))
        
        # Business rules validation
        business_rules = [
            {
                "name": "Product name uniqueness per mine",
                "function": lambda d: self._validate_name_uniqueness(
                    d.get("name"), 
                    d.get("mine_id"), 
                    d.get("id") if is_update else None
                ),
            },
            {
                "name": "Product code uniqueness (global)",
                "function": lambda d: self._validate_code_uniqueness(
                    d.get("code"),
                    d.get("id") if is_update else None
                ),
            },
        ]
        errors.extend(self.validate_business_rules(data, business_rules))
        
        return errors

    def _validate_name_uniqueness(self, name: str, mine_id: int, exclude_id: Optional[int] = None) -> tuple[bool, str]:
        """Validate that product name is unique within the mine."""
        if not name or not mine_id:
            return True, ""
        
        try:
            exists = self.repo.exists_by_name(name, mine_id=mine_id, exclude_id=exclude_id)
            if exists:
                return False, f"Product with name '{name}' already exists in this mine"
            return True, ""
        except Exception as e:
            return False, f"Error checking name uniqueness: {str(e)}"

    def _validate_code_uniqueness(self, code: Optional[str], exclude_id: Optional[int] = None) -> tuple[bool, str]:
        """Validate that product code is globally unique."""
        if not code:
            return True, ""
        
        try:
            # Check if code exists globally (any mine)
            exists = self.repo.exists_by_name(code, mine_id=None, exclude_id=exclude_id)
            if exists:
                return False, f"Product with code '{code}' already exists"
            return True, ""
        except Exception as e:
            return False, f"Error checking code uniqueness: {str(e)}"

    # ─────────────────────────── crud operations ──────────────────────────── #

    def create_product(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Create a new product.
        
        Args:
            data: Product data dictionary
            
        Returns:
            Service response with created product data
        """
        # Sanitize input data
        clean_data = {k: self.sanitize(v) for k, v in data.items()}
        
        # Validate data
        validation_errors = self._validate_product_data(clean_data, is_update=False)
        if validation_errors:
            return self.validation_error(validation_errors)

        def create_operation():
            try:
                product = self.repo.create(clean_data)
                db.session.commit()
                return product
            except DuplicateError as e:
                db.session.rollback()
                raise ValueError(f"Duplicate product: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to create product: {str(e)}")

        result = self.safe_repository_operation("create", create_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        return self.ok(
            "Product created successfully",
            data=result.to_dict(deep=True),
            metadata={"product_id": result.id}
        )

    def get_product(self, product_id: int, include_mine: bool = False) -> Dict[str, Any]:
        """
        Get a product by ID.
        
        Args:
            product_id: Product ID
            include_mine: Whether to include mine data
            
        Returns:
            Service response with product data
        """
        cache_key = f"product:{product_id}:mine:{include_mine}"
        cached_result = self._cache_get(cache_key)
        if cached_result:
            return self.ok("Product retrieved from cache", data=cached_result)

        def get_operation():
            product = self.repo.get(product_id, with_mine=include_mine)
            if not product:
                raise NotFoundError(f"Product {product_id} not found")
            return product

        result = self.safe_repository_operation("get", get_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        product_data = result.to_dict(deep=include_mine)
        self._cache_set(cache_key, product_data, timeout=300)
        
        return self.ok("Product retrieved successfully", data=product_data)

    def update_product(self, product_id: int, data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Update a product.
        
        Args:
            product_id: Product ID
            data: Updated product data
            
        Returns:
            Service response with updated product data
        """
        # Sanitize input data
        clean_data = {k: self.sanitize(v) for k, v in data.items()}
        clean_data["id"] = product_id  # Add ID for validation
        
        # Validate data
        validation_errors = self._validate_product_data(clean_data, is_update=True)
        if validation_errors:
            return self.validation_error(validation_errors)

        def update_operation():
            try:
                product = self.repo.update_fields(product_id, clean_data)
                db.session.commit()
                return product
            except NotFoundError as e:
                raise ValueError(f"Product not found: {str(e)}")
            except DuplicateError as e:
                db.session.rollback()
                raise ValueError(f"Duplicate product: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to update product: {str(e)}")

        result = self.safe_repository_operation("update", update_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Clear related cache entries
        self.clear_cache(f"product:{product_id}")
        
        return self.ok(
            "Product updated successfully",
            data=result.to_dict(deep=True),
            metadata={"product_id": result.id}
        )

    def delete_product(self, product_id: int, soft_delete: bool = True) -> Dict[str, Any]:
        """
        Delete a product.
        
        Args:
            product_id: Product ID
            soft_delete: Whether to perform soft delete
            
        Returns:
            Service response
        """
        def delete_operation():
            try:
                self.repo.delete(product_id, soft=soft_delete)
                db.session.commit()
                return True
            except NotFoundError as e:
                raise ValueError(f"Product not found: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to delete product: {str(e)}")

        result = self.safe_repository_operation("delete", delete_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Clear related cache entries
        self.clear_cache(f"product:{product_id}")
        
        delete_type = "soft deleted" if soft_delete else "permanently deleted"
        return self.ok(f"Product {delete_type} successfully")

    def restore_product(self, product_id: int) -> Dict[str, Any]:
        """
        Restore a soft-deleted product.
        
        Args:
            product_id: Product ID
            
        Returns:
            Service response
        """
        def restore_operation():
            try:
                self.repo.restore(product_id)
                db.session.commit()
                return True
            except NotFoundError as e:
                raise ValueError(f"Product not found or cannot be restored: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to restore product: {str(e)}")

        result = self.safe_repository_operation("restore", restore_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Clear related cache entries
        self.clear_cache(f"product:{product_id}")
        
        return self.ok("Product restored successfully")

    # ─────────────────────────── search and listing ───────────────────────── #

    def list_products(
        self,
        page: int = 1,
        per_page: int = 20,
        mine_id: Optional[int] = None,
        search_query: Optional[str] = None,
        include_deleted: bool = False,
        sort_by: str = "id",
        sort_direction: str = "asc",
        include_mine: bool = False,
    ) -> Dict[str, Any]:
        """
        List products with filtering and pagination.
        
        Args:
            page: Page number
            per_page: Items per page
            mine_id: Filter by mine ID
            search_query: Search in name/code
            include_deleted: Include soft-deleted products
            sort_by: Sort field (id, name, created_at, updated_at)
            sort_direction: Sort direction (asc, desc)
            include_mine: Include mine data
            
        Returns:
            Service response with paginated product list
        """
        # Create filter
        product_filter = ProductFilter(
            mine_id=mine_id,
            q=search_query,
            include_deleted=include_deleted,
        )
        
        # Create sort
        product_sort = ProductSort(
            field=sort_by,
            direction=sort_direction,
        )
        
        # Create cache key
        cache_key = f"products:page:{page}:per_page:{per_page}:filter:{hash(str(product_filter.__dict__))}:sort:{sort_by}:{sort_direction}:mine:{include_mine}"
        cached_result = self._cache_get(cache_key)
        if cached_result:
            return self.ok("Products retrieved from cache", data=cached_result)

        def list_operation():
            try:
                page_result = self.repo.list(
                    flt=product_filter,
                    sort=product_sort,
                    page=page,
                    per_page=per_page,
                    with_mine=include_mine,
                )
                return page_result
            except Exception as e:
                raise RuntimeError(f"Failed to list products: {str(e)}")

        result = self.safe_repository_operation("list", list_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        # Serialize page result
        page_data = {
            "items": [product.to_dict(deep=include_mine) for product in result.items],
            "page": result.page,
            "per_page": result.per_page,
            "total": result.total,
            "pages": result.pages,
        }
        
        self._cache_set(cache_key, page_data, timeout=60)
        
        return self.ok(
            "Products retrieved successfully",
            data=page_data,
            metadata={
                "total_items": result.total,
                "current_page": result.page,
                "total_pages": result.pages,
            }
        )

    def search_products(self, query: str, mine_id: Optional[int] = None, limit: int = 10) -> Dict[str, Any]:
        """
        Search products by name or code.
        
        Args:
            query: Search query
            mine_id: Optional mine filter
            limit: Maximum results
            
        Returns:
            Service response with search results
        """
        if not query or not query.strip():
            return self.error("Search query is required")
        
        return self.list_products(
            page=1,
            per_page=limit,
            mine_id=mine_id,
            search_query=query.strip(),
            sort_by="name",
            sort_direction="asc",
        )

    def get_products_by_mine(self, mine_id: int, include_deleted: bool = False) -> Dict[str, Any]:
        """
        Get all products for a specific mine.
        
        Args:
            mine_id: Mine ID
            include_deleted: Include soft-deleted products
            
        Returns:
            Service response with mine's products
        """
        return self.list_products(
            page=1,
            per_page=1000,  # Large limit to get all products
            mine_id=mine_id,
            include_deleted=include_deleted,
            sort_by="name",
            sort_direction="asc",
        )

    # ─────────────────────────── batch operations ─────────────────────────── #

    def create_products_batch(self, products_data: List[Dict[str, Any]], mine_id: int) -> Dict[str, Any]:
        """
        Create multiple products in batch for a specific mine.
        
        Args:
            products_data: List of product data dictionaries
            mine_id: Mine ID to associate all products with
            
        Returns:
            Service response with created products data
        """
        if not products_data:
            return self.error("Products data is required")
        
        # Sanitize input data
        clean_products_data = [
            {k: self.sanitize(v) for k, v in product.items()} 
            for product in products_data
        ]
        
        # Add mine_id to all products
        for product_data in clean_products_data:
            product_data["mine_id"] = mine_id
        
        # Validate each product
        all_errors = []
        for i, product_data in enumerate(clean_products_data):
            validation_errors = self._validate_product_data(product_data, is_update=False)
            for error in validation_errors:
                all_errors.append(f"Product {i+1}: {error}")
        
        if all_errors:
            return self.validation_error(all_errors)
        
        # Check for duplicate names within the batch
        names = [p.get("name", "").strip() for p in clean_products_data if p.get("name")]
        duplicate_names = [name for name in set(names) if names.count(name) > 1]
        if duplicate_names:
            return self.validation_error([f"Duplicate product names in batch: {', '.join(duplicate_names)}"])
        
        # Check for duplicate codes within the batch
        codes = [p.get("code", "").strip() for p in clean_products_data if p.get("code")]
        duplicate_codes = [code for code in set(codes) if codes.count(code) > 1]
        if duplicate_codes:
            return self.validation_error([f"Duplicate product codes in batch: {', '.join(duplicate_codes)}"])

        def create_batch_operation():
            try:
                created_products = []
                
                for product_data in clean_products_data:
                    product = self.repo.create(product_data)
                    created_products.append(product)
                
                # Commit all at once
                db.session.commit()
                
                return created_products
                
            except DuplicateError as e:
                db.session.rollback()
                raise ValueError(f"Duplicate product in batch: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to create products batch: {str(e)}")

        result = self.safe_repository_operation("create_batch", create_batch_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
        
        # Format response data
        products_data = [product.to_dict(deep=True) for product in result]
        
        return self.ok(
            f"Successfully created {len(result)} products",
            data={
                "products": products_data,
                "summary": {
                    "total_created": len(result),
                    "mine_id": mine_id,
                }
            },
            metadata={
                "products_created": len(result),
                "mine_id": mine_id,
            }
        )

    def update_products_batch(self, updates: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Update multiple products in batch.
        
        Args:
            updates: List of update dictionaries with 'id' and update data
            
        Returns:
            Service response with updated products data
        """
        if not updates:
            return self.error("Updates data is required")
        
        # Validate that all updates have an ID
        for i, update_data in enumerate(updates):
            if "id" not in update_data:
                return self.validation_error([f"Update {i+1}: 'id' is required"])
        
        def update_batch_operation():
            try:
                updated_products = []
                
                for update_data in updates:
                    product_id = update_data.pop("id")
                    clean_data = {k: self.sanitize(v) for k, v in update_data.items()}
                    
                    # Validate update data
                    clean_data["id"] = product_id
                    validation_errors = self._validate_product_data(clean_data, is_update=True)
                    if validation_errors:
                        raise ValueError(f"Product {product_id}: {'; '.join(validation_errors)}")
                    
                    product = self.repo.update_fields(product_id, clean_data)
                    updated_products.append(product)
                
                # Commit all at once
                db.session.commit()
                
                return updated_products
                
            except NotFoundError as e:
                db.session.rollback()
                raise ValueError(f"Product not found in batch: {str(e)}")
            except DuplicateError as e:
                db.session.rollback()
                raise ValueError(f"Duplicate product in batch: {str(e)}")
            except Exception as e:
                db.session.rollback()
                raise RuntimeError(f"Failed to update products batch: {str(e)}")

        result = self.safe_repository_operation("update_batch", update_batch_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
        
        # Clear cache for all updated products
        for product in result:
            self.clear_cache(f"product:{product.id}")
        
        # Format response data
        products_data = [product.to_dict(deep=True) for product in result]
        
        return self.ok(
            f"Successfully updated {len(result)} products",
            data={
                "products": products_data,
                "summary": {
                    "total_updated": len(result),
                }
            },
            metadata={
                "products_updated": len(result),
            }
        )

    # ─────────────────────────── statistics and metrics ───────────────────── #

    def get_product_statistics(self) -> Dict[str, Any]:
        """
        Get product statistics.
        
        Returns:
            Service response with statistics
        """
        cache_key = "product_statistics"
        cached_result = self._cache_get(cache_key)
        if cached_result:
            return self.ok("Statistics retrieved from cache", data=cached_result)

        def stats_operation():
            try:
                # Get total products
                total_page = self.repo.list(page=1, per_page=1)
                total_products = total_page.total
                
                # Get deleted products count
                deleted_filter = ProductFilter(only_deleted=True)
                deleted_page = self.repo.list(flt=deleted_filter, page=1, per_page=1)
                deleted_products = deleted_page.total
                
                return {
                    "total_products": total_products,
                    "active_products": total_products - deleted_products,
                    "deleted_products": deleted_products,
                }
            except Exception as e:
                raise RuntimeError(f"Failed to get statistics: {str(e)}")

        result = self.safe_repository_operation("statistics", stats_operation)
        
        if isinstance(result, dict) and not result.get("success"):
            return result
            
        self._cache_set(cache_key, result, timeout=300)
        
        return self.ok("Statistics retrieved successfully", data=result)
