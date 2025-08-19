"""
Advanced BaseService
====================

Adds high‑level features on top of a plain repository:

* built‑in in‑process cache
* rich validation helpers
* performance & error metrics
* event / hook system
* structured logging

The service expects *optionally* a repository with methods such as
``paginate`` or any custom functions you will call through
``safe_repository_operation``.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta
from typing import Any, Callable, Dict, List, Optional, Tuple


class BaseService:
    # ─────────────────────────────── constructor ────────────────────────────── #
    def __init__(self, repository: Any | None = None) -> None:
        """
        Parameters
        ----------
        repository:
            A concrete repository instance (can be injected later).
        """
        self.repository = repository

        # logging
        self.logger = logging.getLogger(f"{self.__class__.__module__}.{self.__class__.__name__}")

        # in‑process cache: {key: (value, ts)}
        self._cache: Dict[str, Tuple[Any, datetime]] = {}
        self._cache_timeout: int = 300  # seconds

        # metrics
        self._metrics: Dict[str, Any] = {
            "operations": {},  # per‑method timing & counts
            "errors": {},      # error_code → count
            "cache_hits": 0,
            "cache_misses": 0,
        }

        # hooks registry
        self._hooks: Dict[str, List[Callable]] = {
            "before_create": [],
            "after_create": [],
            "before_update": [],
            "after_update": [],
            "before_delete": [],
            "after_delete": [],
            "on_error": [],
        }

    # ───────────────────────────── response helpers ─────────────────────────── #
    @staticmethod
    def _utc_iso() -> str:
        return datetime.utcnow().isoformat()

    def ok(
        self,
        message: str,
        data: Any = None,
        *,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Standard success envelope."""
        resp: Dict[str, Any] = {
            "success": True,
            "message": message,
            "data": data,
            "errors": [],
            "timestamp": self._utc_iso(),
        }
        if metadata:
            resp["metadata"] = metadata
        return resp

    def error(
        self,
        message: str,
        *,
        errors: Optional[List[str]] = None,
        error_code: str | None = None,
        data: Any = None,
    ) -> Dict[str, Any]:
        """Standard error envelope."""
        resp: Dict[str, Any] = {
            "success": False,
            "message": message,
            "data": data,
            "errors": errors or [],
            "timestamp": self._utc_iso(),
        }
        if error_code:
            resp["error_code"] = error_code
            self._record_error(error_code)
        else:
            self._record_error("UNKNOWN_ERROR")
        return resp

    def validation_error(self, errors: List[str]) -> Dict[str, Any]:
        return self.error(
            "Validation error",
            errors=errors,
            error_code="VALIDATION_ERROR",
        )

    # ───────────────────────────── hook system ─────────────────────────────── #
    def add_hook(self, event: str, callback: Callable) -> None:
        if event not in self._hooks:
            raise ValueError(f"Unknown hook '{event}'")
        self._hooks[event].append(callback)

    def _fire_hooks(self, event: str, *args, **kwargs) -> None:
        for cb in self._hooks.get(event, []):
            try:
                cb(*args, **kwargs)
            except Exception as exc:  # noqa: BLE001
                self.logger.error("Hook %s failed: %s", event, exc)

    # ────────────────────────────── caching ────────────────────────────────── #
    def _cache_get(self, key: str) -> Any | None:
        entry = self._cache.get(key)
        if not entry:
            self._metrics["cache_misses"] += 1
            return None

        value, ts = entry
        if (datetime.utcnow() - ts).total_seconds() < self._cache_timeout:
            self._metrics["cache_hits"] += 1
            return value

        # expired
        self._cache.pop(key, None)
        self._metrics["cache_misses"] += 1
        return None

    def _cache_set(self, key: str, value: Any, timeout: int | None = None) -> None:
        self._cache[key] = (value, datetime.utcnow())
        if timeout and timeout != self._cache_timeout:
            # In production you would schedule eviction (Celery/Redis TTL/…)
            pass

    def clear_cache(self, pattern: str | None = None) -> None:
        if pattern is None:
            self._cache.clear()
            return
        for k in list(self._cache):
            if pattern in k:
                self._cache.pop(k, None)

    # ───────────────────────────── validation ──────────────────────────────── #
    @staticmethod
    def _is_empty(value: Any) -> bool:
        return value is None or (isinstance(value, str) and not value.strip())

    def validate_required(self, payload: Dict[str, Any], required: List[str]) -> List[str]:
        return [f"Field '{f}' is required" for f in required if self._is_empty(payload.get(f))]

    def validate_constraints(
        self,
        payload: Dict[str, Any],
        constraints: Dict[str, Dict[str, Any]],
    ) -> List[str]:
        """
        Generic field‑level validation rules.

        constraints = {
            "name": {"type": str, "min_length": 3},
            "age":  {"type": int, "min_value": 0},
            ...
        }
        """
        out: List[str] = []

        for field, cfg in constraints.items():
            val = payload.get(field)
            if val is None:
                continue

            # type check
            if "type" in cfg and not isinstance(val, cfg["type"]):
                out.append(f"Field '{field}' must be of type {cfg['type'].__name__}")
                continue  # avoid cascading errors

            # string length
            if isinstance(val, str):
                min_len = cfg.get("min_length")
                max_len = cfg.get("max_length")
                if min_len and len(val.strip()) < min_len:
                    out.append(f"Field '{field}' must contain ≥ {min_len} chars")
                if max_len and len(val.strip()) > max_len:
                    out.append(f"Field '{field}' must contain ≤ {max_len} chars")

            # numeric bounds
            if isinstance(val, (int, float)):
                min_val = cfg.get("min_value")
                max_val = cfg.get("max_value")
                if min_val is not None and val < min_val:
                    out.append(f"Field '{field}' must be ≥ {min_val}")
                if max_val is not None and val > max_val:
                    out.append(f"Field '{field}' must be ≤ {max_val}")

            # regex
            if (pat := cfg.get("pattern")) and isinstance(val, str):
                if not re.match(pat, val):
                    out.append(f"Field '{field}' does not match required format")

            # custom validator
            if callable(cfg.get("validator")):
                ok, msg = cfg["validator"](val)  # type: ignore[arg-type]
                if not ok:
                    out.append(f"Field '{field}': {msg}")

        return out

    @staticmethod
    def validate_business_rules(
        payload: Dict[str, Any],
        rules: List[Dict[str, Any]],
    ) -> List[str]:
        """
        Execute arbitrary business‑rule functions.

        rules = [{"name": "Check stock", "function": lambda p: (True, "")}, …]
        """
        errs: List[str] = []
        for rule in rules:
            fn = rule.get("function")
            name = rule.get("name", "Business rule")
            if callable(fn):
                try:
                    ok, msg = fn(payload)
                    if not ok:
                        errs.append(f"{name}: {msg}")
                except Exception as exc:  # noqa: BLE001
                    errs.append(f"{name}: {exc}")
        return errs

    # ─────────────────────────── repository wrapper ────────────────────────── #
    def safe_repository_operation(
        self,
        op_name: str,
        op_fn: Callable,
        *args,
        **kwargs,
    ):
        """Run *op_fn* with hooks, metrics, logging and standard error handling."""
        start = datetime.utcnow()
        self._fire_hooks(f"before_{op_name}", *args, **kwargs)

        try:
            result = op_fn(*args, **kwargs)
            self._fire_hooks(f"after_{op_name}", result, *args, **kwargs)
            self._record_operation(op_name, start, True)
            return result
        except Exception as exc:  # noqa: BLE001
            self._fire_hooks("on_error", exc, op_name, *args, **kwargs)
            self._record_operation(op_name, start, False)
            self.logger.error("%s failed: %s", op_name, exc)
            return self.error(
                f"Failed to {op_name}",
                errors=[str(exc)],
                error_code=f"{op_name.upper()}_ERROR",
            )

    # ───────────────────────────── pagination ─────────────────────────────── #
    def paginate(
        self,
        page: int = 1,
        per_page: int = 20,
        **filters,
    ):
        if self.repository is None:
            raise ValueError("Repository not configured")

        key = f"paginate:{page}:{per_page}:{tuple(sorted(filters.items()))}"
        cached = self._cache_get(key)
        if cached is not None:
            return cached

        result = self.repository.paginate(page=page, per_page=per_page, **filters)
        self._cache_set(key, result, timeout=60)
        return result

    # ─────────────────────────── bulk operations ──────────────────────────── #
    def bulk_operation(
        self,
        op_name: str,
        items: List[Dict[str, Any]],
        op_fn: Callable[[Dict[str, Any]], Any],
    ) -> Dict[str, Any]:
        successes, errors = [], []

        for idx, item in enumerate(items):
            try:
                successes.append(op_fn(item))
            except Exception as exc:  # noqa: BLE001
                errors.append(f"Item {idx}: {exc}")

        if errors:
            return self.error(
                f"Bulk {op_name} encountered errors",
                errors=errors,
                data={"successful_items": successes},
            )
        return self.ok(
            f"Bulk {op_name} completed",
            data=successes,
            metadata={"total_items": len(items)},
        )

    # ─────────────────────────── metrics helpers ─────────────────────────── #
    def _record_operation(self, name: str, start: datetime, ok: bool) -> None:
        duration = (datetime.utcnow() - start).total_seconds()
        op = self._metrics["operations"].setdefault(
            name,
            {
                "total_calls": 0,
                "successful_calls": 0,
                "failed_calls": 0,
                "total_duration": 0.0,
                "min_duration": float("inf"),
                "max_duration": 0.0,
            },
        )
        op["total_calls"] += 1
        op["total_duration"] += duration
        op["min_duration"] = min(op["min_duration"], duration)
        op["max_duration"] = max(op["max_duration"], duration)
        if ok:
            op["successful_calls"] += 1
        else:
            op["failed_calls"] += 1

    def _record_error(self, code: str) -> None:
        self._metrics["errors"][code] = self._metrics["errors"].get(code, 0) + 1

    # Public metrics accessor
    def get_metrics(self) -> Dict[str, Any]:
        hits = self._metrics["cache_hits"]
        misses = self._metrics["cache_misses"]
        total = hits + misses
        return {
            "operations": self._metrics["operations"],
            "errors": self._metrics["errors"],
            "cache": {
                "hits": hits,
                "misses": misses,
                "hit_rate": hits / total if total else 0.0,
                "size": len(self._cache),
            },
        }

    def clear_metrics(self) -> None:
        self._metrics = {
            "operations": {},
            "errors": {},
            "cache_hits": 0,
            "cache_misses": 0,
        }

    # ─────────────────────────── misc utilities ─────────────────────────── #
    @staticmethod
    def sanitize(value: str | Any) -> str | Any:
        """Trim a string or return the value untouched."""
        return value.strip() if isinstance(value, str) else value

    @staticmethod
    def format_validation_errors(errs: List[str]) -> str:
        return "; ".join(errs)