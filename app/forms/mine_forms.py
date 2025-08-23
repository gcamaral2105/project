from __future__ import annotations

from typing import Any, Dict, List

from flask_wtf import FlaskForm
from wtforms import FieldList, FormField, HiddenField, StringField, TextAreaField, BooleanField
from wtforms.validators import DataRequired, Length, Optional, ValidationError

from .product_forms import ProductInlineForm


class MineForm(FlaskForm):
    """
    Mine form with a nested list of ProductInlineForm rows.
    Supports:
      - Create Mine with N products
      - Update Mine and sync products (upsert by id/code, delete rows)
      - Optional 'delete_missing_products' checkbox to remove products not listed
    """
    id = HiddenField()  # for updates
    name = StringField("Mine name", validators=[DataRequired(), Length(min=2, max=120)])
    code = StringField("Mine code", validators=[DataRequired(), Length(min=1, max=50)])
    country = StringField("Country", validators=[DataRequired(), Length(min=2, max=100)])
    description = TextAreaField("Description", validators=[Optional(), Length(max=2000)])

    # Product rows
    products = FieldList(FormField(ProductInlineForm), min_entries=0)

    # Sync option: delete products not listed in the form on update
    delete_missing_products = BooleanField("Delete products not listed here", default=False)

    # ------------- Cross-row validations ------------- #
    def validate(self, extra_validators=None) -> bool:
        ok = super().validate(extra_validators=extra_validators)

        # Check duplicate product codes in the submitted rows (client-side coherence only)
        codes_seen: set[str] = set()
        for row in self.products.entries:
            if row._action.data == "delete":
                # Deleting rows need no further checks
                continue
            code = (row.code.data or "").strip()
            name = (row.name.data or "").strip()
            # If row is completely empty, skip (it will be ignored in payload)
            if not any([code, name, (row.description.data or "").strip(), (row.id.data or "").strip()]):
                continue
            if code:
                if code in codes_seen:
                    row.code.errors.append("Duplicated code in form rows.")
                    ok = False
                codes_seen.add(code)

        return ok

    # ------------- Serialization helper ------------- #
    def to_payload(self) -> Dict[str, Any]:
        """
        Build the payload expected by MineService.create_mine / update_mine.
        - For create: ignore id
        - For update: include id if present (handled by the caller)
        - Products: each row is converted via ProductInlineForm.to_payload()
        """
        payload: Dict[str, Any] = {
            "name": (self.name.data or "").strip(),
            "code": (self.code.data or "").strip(),
            "country": (self.country.data or "").strip(),
            "description": (self.description.data or "").strip() or None,
        }

        # products array
        items: List[Dict[str, Any]] = []
        for row in self.products.entries:
            p = row.form.to_payload()
            if p is not None:
                items.append(p)

        # Only include the list if there is anything meaningful
        if items:
            payload["products"] = items

        # Update-only option: delete products not listed
        if self.delete_missing_products.data:
            payload["delete_missing_products"] = True

        return payload
