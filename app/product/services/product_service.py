from __future__ import annotations
from typing import Any, Dict, Optional, Tuple

from app.product.repository.product_repository import ProductRepository
from app.lib.repository.decorators import transactional  # @transactional


class ProductService:
    """
    Regras de negócio de Product.
    - Usa @transactional em métodos que alteram estado (create/update/delete/restore).
    """

    def __init__(self) -> None:
        self.repo = ProductRepository()

    # --------------------- Leituras --------------------- #
    def get(self, product_id: int):
        return self.repo.get_by_id(product_id)

    def list(
        self,
        q: Optional[str],
        page: int,
        per_page: int,
        order_by: Optional[str],
        order_desc: bool,
    ) -> Tuple[list, int]:
        return self.repo.search_paginated(q, page, per_page, order_by, order_desc)

    def list_active(self) -> list:
        return self.repo.get_active()

    def list_deleted(self) -> list:
        return self.repo.get_deleted()

    # --------------------- Escritas (transacionais) --------------------- #
    @transactional
    def create(self, payload: Dict[str, Any]):
        name = (payload.get("name") or "").strip()
        if not name:
            raise ValueError("name is required")
        if self.repo.exists_name(name):
            raise ValueError("A product with this name already exists")

        # O BaseRepository.create faz audit + commit/rollback internos;
        # ainda assim usamos @transactional para orquestrar operações futuras.
        return self.repo.create(**payload)

    @transactional
    def update(self, product_id: int, payload: Dict[str, Any]):
        if "name" in payload and payload["name"]:
            new_name = payload["name"].strip()
            if not new_name:
                raise ValueError("name cannot be empty")
            if self.repo.exists_name(new_name, exclude_id=product_id):
                raise ValueError("A product with this name already exists")

        updated = self.repo.update(product_id, **payload)
        if not updated:
            raise LookupError("Product not found")
        return updated

    @transactional
    def delete(self, product_id: int) -> None:
        ok = self.repo.delete(product_id)  # soft-delete
        if not ok:
            raise LookupError("Product not found")

    @transactional
    def restore(self, product_id: int) -> None:
        ok = self.repo.restore(product_id)
        if not ok:
            raise LookupError("Product not found or not deleted")
