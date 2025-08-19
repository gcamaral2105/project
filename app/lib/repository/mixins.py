"""
Advanced decorators for repository/service layers
=================================================

This module provides reusable decorators you can stack on repository or
service methods to add:

* automatic transactions
* in‑memory result caching
* structured logging
* retry with exponential back‑off
* argument validation
* performance metrics (time & optional memory)
* deprecation warnings

All decorators are framework‑agnostic. If you are using Flask + SQLAlchemy,
just ensure your repository has an attribute called ``session`` that exposes
``commit`` and ``rollback``.
"""

from __future__ import annotations

import functools
import inspect
import logging
import time
import warnings
from datetime import datetime, timedelta
from typing import Any, Callable, Dict, Optional, TypeVar, Tuple

T = TypeVar("T")

# --------------------------------------------------------------------------- #
# Transaction management                                                      #
# --------------------------------------------------------------------------- #
def transactional(rollback_on_error: bool = True) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """
    Wrap the function in a DB transaction (expects ``self.session``).

    Parameters
    ----------
    rollback_on_error:
        Call ``session.rollback()`` if an exception is raised.
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):  # type: ignore[no-self]
            try:
                result: T = func(self, *args, **kwargs)
                if hasattr(self, "session"):
                    self.session.commit()  # type: ignore[attr-defined]
                return result
            except Exception:  # noqa: BLE001
                if rollback_on_error and hasattr(self, "session"):
                    self.session.rollback()  # type: ignore[attr-defined]
                raise

        return wrapper

    return decorator


# --------------------------------------------------------------------------- #
# Simple in‑process result cache                                              #
# --------------------------------------------------------------------------- #
def cached_result(
    timeout: int = 300,
    key_func: Optional[Callable[..., str]] = None,
) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """
    Cache the return value of a method in memory.

    Parameters
    ----------
    timeout:
        Cache expiry in **seconds**.
    key_func:
        Custom function to build the cache key (receives self, *args, **kwargs).
        Default key is ``"<func>:<args>:<sorted(kwargs)>"``.
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        cache: Dict[str, Tuple[T, float]] = {}

        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):  # type: ignore[no-self]
            # Compute key
            cache_key: str = (
                key_func(self, *args, **kwargs)  # type: ignore[misc]
                if key_func
                else f"{func.__name__}:{args}:{tuple(sorted(kwargs.items()))}"
            )

            # Return cached value if fresh
            if cache_key in cache:
                result, ts = cache[cache_key]
                if time.time() - ts < timeout:
                    return result
                cache.pop(cache_key, None)

            # Compute, store, and return
            result: T = func(self, *args, **kwargs)
            cache[cache_key] = (result, time.time())
            return result

        # Expose helpers
        wrapper.clear_cache = lambda: cache.clear()  # type: ignore[attr-defined]
        wrapper.cache_info = lambda: {  # type: ignore[attr-defined]
            "size": len(cache),
            "keys": list(cache.keys()),
        }

        return wrapper

    return decorator


# --------------------------------------------------------------------------- #
# Logging                                                                     #
# --------------------------------------------------------------------------- #
def logged_operation(
    log_level: str = "INFO",
    include_args: bool = False,
) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """
    Emit start / success / error logs around a method call.

    Parameters
    ----------
    log_level:
        'DEBUG' | 'INFO' | 'WARNING' | 'ERROR'.
    include_args:
        Whether to include *args / **kwargs in the start log.
    """

    valid_level = getattr(logging, log_level.upper(), logging.INFO)

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):  # type: ignore[no-self]
            logger = logging.getLogger(f"{self.__class__.__module__}.{self.__class__.__name__}")

            start_msg = (
                f"Starting {func.__name__} args={args}, kwargs={kwargs}"
                if include_args
                else f"Starting {func.__name__}"
            )
            logger.log(valid_level, start_msg)

            start_ts = time.time()
            try:
                result: T = func(self, *args, **kwargs)
                logger.log(valid_level, f"Finished {func.__name__} in {time.time() - start_ts:.3f}s")
                return result
            except Exception as exc:  # noqa: BLE001
                logger.error(f"{func.__name__} failed after {time.time() - start_ts:.3f}s -> {exc}")
                raise

        return wrapper

    return decorator


# --------------------------------------------------------------------------- #
# Retry with exponential back‑off                                             #
# --------------------------------------------------------------------------- #
def retry_on_failure(
    max_retries: int = 3,
    delay: float = 1.0,
    backoff: float = 2.0,
) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """
    Retry a failing method call with exponential back‑off.

    Parameters
    ----------
    max_retries:
        Maximum number of *additional* attempts.
    delay:
        Initial sleep in seconds.
    backoff:
        Multiplier applied to the delay after each failure.
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):  # type: ignore[no-self]
            current_delay = delay
            for attempt in range(max_retries + 1):
                try:
                    return func(self, *args, **kwargs)
                except Exception as exc:  # noqa: BLE001
                    if attempt == max_retries:
                        raise
                    time.sleep(current_delay)
                    current_delay *= backoff

        return wrapper

    return decorator


# --------------------------------------------------------------------------- #
# Argument validation                                                         #
# --------------------------------------------------------------------------- #
def validate_input(**validators: Dict[str, Any]) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """
    Validate incoming arguments before executing the method.

    Examples
    --------
    ```python
    @validate_input(
        name={'func': lambda x: isinstance(x, str) and x, 'message': 'Name must be non‑empty'},
        age={'func': lambda x: isinstance(x, int) and x >= 0, 'message': 'Age >= 0'},
    )
    def create_person(self, name, age): ...
    ```
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        sig = inspect.signature(func)

        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):  # type: ignore[no-self]
            bound = sig.bind(self, *args, **kwargs)
            bound.apply_defaults()

            for param_name, validator in validators.items():
                if param_name not in bound.arguments:
                    continue
                value = bound.arguments[param_name]

                if callable(validator):
                    if not validator(value):  # type: ignore[arg-type]
                        raise ValueError(f"Validation failed for '{param_name}'")
                elif isinstance(validator, dict):
                    check = validator.get("func")
                    message = validator.get("message", f"Validation failed for '{param_name}'")
                    if callable(check) and not check(value):
                        raise ValueError(message)

            return func(*bound.args, **bound.kwargs)

        return wrapper

    return decorator


# --------------------------------------------------------------------------- #
# Performance measurement                                                     #
# --------------------------------------------------------------------------- #
def measure_performance(store_metrics: bool = True) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """
    Time (and optionally track memory for Linux/macOS) of a method call.

    Exposes two helper methods on the wrapped function:

    * ``fn.get_metrics()`` → aggregate dict
    * ``fn.clear_metrics()``
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        metrics: Dict[str, Dict[str, Any]] = {}

        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):  # type: ignore[no-self]
            start = time.time()
            mem_start = None

            # Optional memory usage
            try:
                import os
                import psutil  # type: ignore
                process = psutil.Process(os.getpid())
                mem_start = process.memory_info().rss
            except Exception:  # noqa: BLE001
                pass

            try:
                result: T = func(self, *args, **kwargs)
                elapsed = time.time() - start
                mem_used = None

                if mem_start is not None:
                    try:
                        mem_used = process.memory_info().rss - mem_start  # type: ignore[has-type]
                    except Exception:
                        pass

                if store_metrics:
                    key = f"{self.__class__.__name__}.{func.__name__}"
                    data = metrics.setdefault(
                        key,
                        {
                            "calls": 0,
                            "total_time": 0.0,
                            "min_time": float("inf"),
                            "max_time": 0.0,
                            "avg_time": 0.0,
                            "memory_usage": [],
                            "errors": 0,
                        },
                    )
                    data["calls"] += 1
                    data["total_time"] += elapsed
                    data["min_time"] = min(data["min_time"], elapsed)
                    data["max_time"] = max(data["max_time"], elapsed)
                    data["avg_time"] = data["total_time"] / data["calls"]
                    if mem_used is not None:
                        data["memory_usage"].append(mem_used)

                return result
            except Exception:
                if store_metrics:
                    key = f"{self.__class__.__name__}.{func.__name__}"
                    metrics.setdefault(key, {"errors": 0})["errors"] += 1  # type: ignore[index]
                raise

        # Attach helpers
        wrapper.get_metrics = lambda: metrics  # type: ignore[attr-defined]
        wrapper.clear_metrics = lambda: metrics.clear()  # type: ignore[attr-defined]

        return wrapper

    return decorator


# --------------------------------------------------------------------------- #
# Deprecation warning                                                         #
# --------------------------------------------------------------------------- #
def deprecated(
    reason: str = "",
    alternative: str = "",
) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """
    Mark a method as deprecated.

    Parameters
    ----------
    reason:
        Why this method is deprecated.
    alternative:
        Suggested replacement method name.
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        msg = f"Method '{func.__name__}' is deprecated"
        if reason:
            msg += f": {reason}"
        if alternative:
            msg += f". Use '{alternative}' instead."

        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            warnings.warn(msg, DeprecationWarning, stacklevel=2)
            return func(*args, **kwargs)

        return wrapper

    return decorator


# --------------------------------------------------------------------------- #
# Example usage                                                               #
# --------------------------------------------------------------------------- #
class ExampleRepository:
    """Showcase of stacking multiple decorators."""

    # Dummy session just to illustrate transactional decorator
    class _DummySession:
        def commit(self): ...
        def rollback(self): ...

    def __init__(self):
        self.session = self._DummySession()

    @transactional()
    @logged_operation(log_level="INFO", include_args=True)
    @measure_performance()
    def create_entity(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """Simulated create."""
        return {"id": 1, "data": data}

    @cached_result(timeout=300)
    @measure_performance()
    def get_expensive_data(self, query: str) -> str:
        """Simulated expensive call."""
        time.sleep(0.1)
        return f"Result for {query}"

    @retry_on_failure(max_retries=3, delay=0.5)
    def unreliable_operation(self) -> str:
        """Randomly fails ~70 % of the time."""
        import random

        if random.random() < 0.7:
            raise RuntimeError("Operation failed")
        return "Success"

    @validate_input(
        name={
            "func": lambda x: isinstance(x, str) and x.strip(),
            "message": "Name must be a non‑empty string",
        },
        age={
            "func": lambda x: isinstance(x, int) and x >= 0,
            "message": "Age must be a non‑negative integer",
        },
    )
    def create_person(self, name: str, age: int) -> Dict[str, Any]:
        """Show argument validation."""
        return {"name": name, "age": age}

    @deprecated(reason="Legacy implementation", alternative="new_method")
    def old_method(self) -> str:
        return "Old implementation"