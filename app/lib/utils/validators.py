"""
Validation utilities – advanced
===============================

Reusable helpers for complex, cross‑application validation:

* field‑level rules (type, length, ranges, regex, enumerations…)
* business‑rule callbacks
* CPF / CNPJ algorithms
* convenient one‑liners for e‑mail / CPF / CNPJ checks
"""

from __future__ import annotations

import re
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Dict, List, Optional, Tuple, Union


class ValidationUtils:
    """Static helpers used by service / repository layers."""

    # ─────────────────────────── regex patterns ─────────────────────────── #
    EMAIL_PATTERN: str = r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"
    PHONE_PATTERN: str = r"^\+?1?\d{9,15}$"
    CPF_PATTERN: str = r"^\d{3}\.\d{3}\.\d{3}-\d{2}$"
    CNPJ_PATTERN: str = r"^\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}$"

    # ───────────────────────── public orchestrator ──────────────────────── #
    @classmethod
    def validate(
        cls,
        payload: Dict[str, Any],
        rules: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Main entry‑point.

        Parameters
        ----------
        payload:
            Data to validate.
        rules:
            Dict structured as::

                {
                    "fields": { ... },
                    "business_rules": [ ... ],
                    "relationships": { ... }
                }

        Returns
        -------
        dict
            {
                "valid": bool,
                "errors": [msg, ...],
                "field_errors": {"field": [msg, ...], ...}
            }
        """
        errors: List[str] = []

        # field‑level
        for name, cfg in rules.get("fields", {}).items():
            errors.extend(cls._validate_field(payload.get(name), name, cfg))

        # business rules
        for br in rules.get("business_rules", []):
            errors.extend(cls._validate_business_rule(payload, br))

        # relationships (placeholder for FK / cardinality validations)
        for rel, cfg in rules.get("relationships", {}).items():
            errors.extend(cls._validate_relationship(payload, rel, cfg))

        return {
            "valid": not errors,
            "errors": errors,
            "field_errors": cls._group_by_field(errors),
        }

    # ────────────────────────── field validators ────────────────────────── #
    @classmethod
    def _validate_field(
        cls,
        value: Any,
        name: str,
        cfg: Dict[str, Any],
    ) -> List[str]:
        out: List[str] = []

        # required?
        if cfg.get("required") and cls._empty(value):
            out.append(f"Field '{name}' is required")
            return out

        if cls._empty(value):  # optional & empty → skip other checks
            return out

        # type check
        if (tp := cfg.get("type")):
            type_errors = cls._check_type(value, name, tp)
            out.extend(type_errors)
            if type_errors:  # wrong type → abort further checks
                return out

        # specialised validations
        match cfg.get("type"):
            case "string":
                out.extend(cls._string_rules(value, name, cfg))
            case "number":
                out.extend(cls._number_rules(value, name, cfg))
            case "email":
                out.extend(cls._email_rules(value, name))
            case "date":
                out.extend(cls._date_rules(value, name, cfg))
            case "cpf":
                out.extend(cls._cpf_rules(value, name))
            case "cnpj":
                out.extend(cls._cnpj_rules(value, name))

        # custom validator
        if callable(cfg.get("validator")):
            try:
                ok, msg = cfg["validator"](value)
                if not ok:
                    out.append(f"Field '{name}': {msg}")
            except Exception as exc:  # noqa: BLE001
                out.append(f"Field '{name}' custom validation failed: {exc}")

        return out

    # ────────────────────────── specific rule sets ──────────────────────── #
    @staticmethod
    def _string_rules(val: str, name: str, cfg: Dict[str, Any]) -> List[str]:
        res: List[str] = []
        if not isinstance(val, str):
            return res

        min_len = cfg.get("min_length")
        max_len = cfg.get("max_length")
        if min_len and len(val.strip()) < min_len:
            res.append(f"Field '{name}' must have ≥ {min_len} chars")
        if max_len and len(val.strip()) > max_len:
            res.append(f"Field '{name}' must have ≤ {max_len} chars")

        pattern = cfg.get("pattern")
        if pattern and not re.match(pattern, val):
            label = cfg.get("pattern_name", "required pattern")
            res.append(f"Field '{name}' does not match {label}")

        allowed = cfg.get("allowed_values")
        if allowed and val not in allowed:
            res.append(f"Field '{name}' must be one of: {', '.join(map(str, allowed))}")
        return res

    @staticmethod
    def _number_rules(
        val: Union[int, float, Decimal],
        name: str,
        cfg: Dict[str, Any],
    ) -> List[str]:
        res: List[str] = []
        if not isinstance(val, (int, float, Decimal)):
            return res

        min_val = cfg.get("min_value")
        max_val = cfg.get("max_value")
        if min_val is not None and val < min_val:
            res.append(f"Field '{name}' must be ≥ {min_val}")
        if max_val is not None and val > max_val:
            res.append(f"Field '{name}' must be ≤ {max_val}")

        if cfg.get("integer_only") and not isinstance(val, int):
            res.append(f"Field '{name}' must be an integer")
        if cfg.get("positive_only") and val <= 0:
            res.append(f"Field '{name}' must be positive")
        return res

    @classmethod
    def _email_rules(cls, val: str, name: str) -> List[str]:
        if not isinstance(val, str) or re.match(cls.EMAIL_PATTERN, val):
            return []
        return [f"Field '{name}' must be a valid e‑mail"]

    @classmethod
    def _date_rules(
        cls,
        val: Union[str, date, datetime],
        name: str,
        cfg: Dict[str, Any],
    ) -> List[str]:
        res: List[str] = []

        # coerce str → date
        if isinstance(val, str):
            try:
                val = (
                    datetime.fromisoformat(val.replace("Z", "+00:00"))
                    if ("T" in val or " " in val)
                    else datetime.strptime(val, "%Y-%m-%d").date()
                )
            except ValueError:
                return [f"Field '{name}' must be YYYY‑MM‑DD or ISO datetime"]

        if not isinstance(val, (date, datetime)):
            return [f"Field '{name}' must be a date or datetime"]

        min_d = cfg.get("min_date")
        max_d = cfg.get("max_date")
        if min_d and val < min_d:
            res.append(f"Field '{name}' must be after {min_d}")
        if max_d and val > max_d:
            res.append(f"Field '{name}' must be before {max_d}")
        return res

    # CPF / CNPJ
    @classmethod
    def _cpf_rules(cls, val: str, name: str) -> List[str]:
        if cls._cpf_field_errors(val):
            return [f"Field '{name}' is not a valid CPF"]
        return []

    @classmethod
    def _cnpj_rules(cls, val: str, name: str) -> List[str]:
        if cls._cnpj_field_errors(val):
            return [f"Field '{name}' is not a valid CNPJ"]
        return []

    # ───────────────────────── business / relationship ────────────────────── #
    @staticmethod
    def _validate_business_rule(payload: Dict[str, Any], rule: Dict[str, Any]) -> List[str]:
        fn = rule.get("function")
        name = rule.get("name", "Business rule")
        if not callable(fn):
            return []
        try:
            ok, msg = fn(payload)
            return [] if ok else [f"{name}: {msg}"]
        except Exception as exc:  # noqa: BLE001
            return [f"{name}: {exc}"]

    @staticmethod
    def _validate_relationship(
        payload: Dict[str, Any],
        relationship: str,
        cfg: Dict[str, Any],
    ) -> List[str]:
        # Placeholder: implement FK existence, cardinality, etc.
        return []

    # ───────────────────────── type helpers & utils ──────────────────────── #
    @classmethod
    def _check_type(cls, value: Any, name: str, expected: str) -> List[str]:
        mapping = {
            "string": str,
            "number": (int, float, Decimal),
            "integer": int,
            "float": float,
            "boolean": bool,
            "list": list,
            "dict": dict,
            "date": (date, datetime),
            "email": str,
            "cpf": str,
            "cnpj": str,
        }
        tp = mapping.get(expected)
        if tp and not isinstance(value, tp):
            return [f"Field '{name}' must be of type {expected}"]
        return []

    @staticmethod
    def _empty(value: Any) -> bool:
        return (
            value is None
            or (isinstance(value, str) and not value.strip())
            or (isinstance(value, (list, dict)) and not value)
        )

    # group errors by field
    @staticmethod
    def _group_by_field(errs: List[str]) -> Dict[str, List[str]]:
        grouped: Dict[str, List[str]] = {}
        for msg in errs:
            if "Field '" in msg:
                start = msg.find("Field '") + 7
                end = msg.find("'", start)
                if end > start:
                    field = msg[start:end]
                    grouped.setdefault(field, []).append(msg)
                    continue
            grouped.setdefault("general", []).append(msg)
        return grouped

    # ───────────────────────── CPF / CNPJ core logic ─────────────────────── #
    # Return True if CPF digits are OK
    @classmethod
    def _validate_cpf_digits(cls, digits: str) -> bool:
        sums = [
            sum(int(digits[i]) * (10 - i) for i in range(9)),
            sum(int(digits[i]) * (11 - i) for i in range(10)),
        ]
        check = [(11 - (s % 11)) % 10 for s in sums]
        return digits[-2:] == "".join(map(str, check))

    # Return True if CNPJ digits are OK
    @classmethod
    def _validate_cnpj_digits(cls, digits: str) -> bool:
        w1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
        w2 = [6] + w1
        sums = [
            sum(int(digits[i]) * w1[i] for i in range(12)),
            sum(int(digits[i]) * w2[i] for i in range(13)),
        ]
        check = [(11 - (s % 11)) % 10 for s in sums]
        return digits[-2:] == "".join(map(str, check))

    @classmethod
    def _cpf_field_errors(cls, value: str) -> List[str]:
        if not isinstance(value, str):
            return ["CPF must be a string"]
        digits = re.sub(r"\D", "", value)
        if len(digits) != 11 or digits == digits[0] * 11 or not cls._validate_cpf_digits(digits):
            return ["invalid CPF"]
        return []

    @classmethod
    def _cnpj_field_errors(cls, value: str) -> List[str]:
        if not isinstance(value, str):
            return ["CNPJ must be a string"]
        digits = re.sub(r"\D", "", value)
        if len(digits) != 14 or digits == digits[0] * 14 or not cls._validate_cnpj_digits(digits):
            return ["invalid CNPJ"]
        return []

    # ───────────────────────── convenience one‑liners ────────────────────── #
def validate_email(email: str) -> bool:
    return bool(re.match(ValidationUtils.EMAIL_PATTERN, email))


def validate_cpf(cpf: str) -> bool:
    return not ValidationUtils._cpf_field_errors(cpf)


def validate_cnpj(cnpj: str) -> bool:
    return not ValidationUtils._cnpj_field_errors(cnpj)


def create_validation_rules(**kwargs) -> Dict[str, Any]:
    """
    Fluent builder to keep rule objects concise, e.g.:

    ```python
    rules = create_validation_rules(
        fields={
            "name":  {"type": "string", "required": True, "min_length": 3},
            "email": {"type": "email",  "required": True},
        }
    )
    ```
    """

    return kwargs

def positive(value, field="value"):
    if value is None or value <= 0:
        raise ValueError(f"{field} must be > 0")
    return value

def non_negative(value, field="value"):
    if value is None or value < 0:
        raise ValueError(f"{field} must be >= 0")
    return value

def valid_period(start: date, end: date):
    if not start or not end or start > end:
        raise ValueError("Invalid period: start must be <= end")
    return True
