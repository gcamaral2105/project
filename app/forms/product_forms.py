from __future__ import annotations

from wtforms import Form, StringField, TextAreaField, HiddenField, SelectField
from wtforms.validators import DataRequired, Length, Optional


class ProductForm(Form):
    """
    Standalone Product form (useful for a pure product page).
    Not used for the nested Mine form (see ProductInlineForm below).
    """
    id = HiddenField()  # for updates; empty for create
    name = StringField("Name", validators=[DataRequired(), Length(min=2, max=120)])
    code = StringField("Code", validators=[Optional(), Length(min=1, max=50)])
    description = TextAreaField("Description", validators=[Optional(), Length(max=2000)])


class ProductInlineForm(Form):
    """
    Product subform to be used inside the Mine form’s FieldList.
    Includes a small _action to mark row deletions (keep/update/delete).
    """
    id = HiddenField()  # existing product id for updates
    name = StringField("Product name", validators=[Optional(), Length(min=2, max=120)])
    code = StringField("Code", validators=[Optional(), Length(min=1, max=50)])
    description = TextAreaField("Description", validators=[Optional(), Length(max=2000)])
    _action = SelectField(
        "Action",
        choices=[("keep", "Keep/Upsert"), ("delete", "Delete")],
        default="keep",
        validators=[DataRequired()],
    )

    def to_payload(self) -> dict | None:
        """
        Turn one row into a payload dict for the service.
        - If _action == delete: only send identifiers + action
        - If keep: only send fields that are present (id/code/name/description)
        Returns None for completely empty rows.
        """
        action = (self._action.data or "keep").strip().lower()
        pid = self.id.data.strip() if self.id.data else None
        code = self.code.data.strip() if self.code.data else None
        name = (self.name.data or "").strip()
        desc = (self.description.data or "").strip()

        # Completely empty row? ignore
        if action == "keep" and not any([pid, code, name, desc]):
            return None

        if action == "delete":
            payload = {}
            if pid:
                payload["id"] = int(pid)
            if code:
                payload["code"] = code
            payload["_action"] = "delete"
            return payload

        # keep/upsert
        out: dict = {}
        if pid:
            out["id"] = int(pid)
        if code:
            out["code"] = code
        if name:
            out["name"] = name
        if desc:
            out["description"] = desc
        return out if out else None
