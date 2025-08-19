"""
Lib - Biblioteca interna da aplicação.

Este módulo contém componentes reutilizáveis que podem ser usados
por qualquer parte da aplicação ou até mesmo extraídos como
biblioteca externa no futuro.
"""

__version__ = "1.0.0"
__author__ = "HQ Development Team"

# Imports principais
from .repository import BaseRepository, RepositoryMixin
from .services import BaseService
from .utils import ValidationUtils, StringUtils
from .base_model import BaseModel

__all__ = [
    'BaseRepository',
    'RepositoryMixin',
    'BaseService', 
    'ValidationUtils',
    'StringUtils',
    'BaseModel'
]