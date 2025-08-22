from __future__ import annotations
from functools import wraps
from typing import Callable

from app.extensions import db


def transactional(fn: Callable):
    """Abre transação, faz commit no sucesso e rollback em exceção.
    Pode ser usado em Services que orquestram múltiplos repositories.
    """

    @wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            result = fn(*args, **kwargs)
            db.session.commit()
            return result
        except Exception:
            db.session.rollback()
            raise

    return wrapper
