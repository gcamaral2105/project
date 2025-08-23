from __future__ import annotations

from typing import Any, Dict, Optional

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.extensions import db
from app.lib.repository.decorators import transactional
from app.lib.services.base import BaseService
from app.product.repository.product_repository import ProductRepository


class ProductService(BaseService):
    """
    Product service with simple validation and standard envelopes.
    """

    def __init__(self, session: Optional[Session] = None) -> None:
        super().__init__()
        self.session = session or db.session
        self.repository = ProductRepository(self.session)

    # ------------------- write ops -------------------
    @transactional
    def create(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        errs = self.validate_required(payload, ["name"])
        if errs:
            return self.validation_error(errs)

        try:
            entity = self.repository.create(payload)
        except IntegrityError as exc:  # unique name/code, etc.
            # Re-raise to be captured by @transactional? No: we want envelope.
            self.session.rollback()
            return self.validation_error([f"Integrity error: {exc.orig}"])  # type: ignore[attr-defined]

        return self.ok("Created", data=entity.to_dict())

    @transactional
    def update(self, product_id: int, payload: Dict[str, Any]) -> Dict[str, Any]:
        entity = self.repository.update_fields(product_id, payload)
        return self.ok("Updated", data=entity.to_dict())

    @transactional
    def delete(self, product_id: int, *, soft: bool = True) -> Dict[str, Any]:
        self.repository.delete(product_id, soft=soft)
        return self.ok("Deleted")

    @transactional
    def restore(self, product_id: int) -> Dict[str, Any]:
        self.repository.restore(product_id)
        return self.ok("Restored")

    # ------------------- read ops -------------------
    def get(self, product_id: int) -> Dict[str, Any]:
        entity = self.repository.get(product_id)
        if not entity:
            return self.error("Product not found", error_code="NOT_FOUND")
        return self.ok("OK", data=entity.to_dict())

    def list(self, *, page: int = 1, per_page: int = 20, **filters) -> Dict[str, Any]:
        page_obj = self.repository.paginate(page=page, per_page=per_page, **filters)
        return self.ok(
            "OK",
            data=[e.to_dict() for e in page_obj.items],
            metadata={
                "total": page_obj.total,
                "page": page_obj.page,
                "per_page": page_obj.per_page,
                "pages": page_obj.pages,
            },
        )
