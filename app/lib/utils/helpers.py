"""
Generic helper utilities (strings, dates, numbers, dicts)
=========================================================
"""

from __future__ import annotations

import re
import unicodedata
from datetime import date, datetime, timedelta
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Dict, List, Optional, Union


# ─────────────────────────────── strings ──────────────────────────────── #
class StringUtils:
    """String‑handling helpers."""

    # slug / truncation / whitespace
    @staticmethod
    def slugify(text: str, sep: str = "-") -> str:
        """Convert text to a URL‑friendly slug."""
        if not text:
            return ""
        text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
        text = re.sub(r"[^\w\s-]", "", text.lower())
        text = re.sub(r"[-\s]+", sep, text)
        return text.strip(sep)

    @staticmethod
    def truncate(text: str, max_len: int, suffix: str = "...") -> str:
        """Trim text to *max_len* keeping whole words."""
        if not text or len(text) <= max_len:
            return text
        head = text[: max_len - len(suffix)]
        last_space = head.rfind(" ")
        if last_space > 0:
            head = head[:last_space]
        return head + suffix

    @staticmethod
    def clean_whitespace(text: str) -> str:
        """Collapse multiple spaces and normalise line breaks."""
        if not text:
            return ""
        text = text.strip()
        text = re.sub(r"\s+", " ", text)
        return re.sub(r"\r\n|\r", "\n", text)

    # extraction / masking
    @staticmethod
    def extract_numbers(text: str) -> List[str]:
        return re.findall(r"\d+(?:\.\d+)?", text) if text else []

    @staticmethod
    def mask(text: str, mask_char: str = "*", visible: int = 4) -> str:
        if not text or len(text) <= visible:
            return text
        return mask_char * (len(text) - visible) + text[-visible:]

    # Brazilian formats
    @staticmethod
    def format_cpf(cpf: str) -> str:
        nums = re.sub(r"\D", "", cpf or "")
        return cpf if len(nums) != 11 else f"{nums[:3]}.{nums[3:6]}.{nums[6:9]}-{nums[9:]}"

    @staticmethod
    def format_cnpj(cnpj: str) -> str:
        nums = re.sub(r"\D", "", cnpj or "")
        return (
            cnpj
            if len(nums) != 14
            else f"{nums[:2]}.{nums[2:5]}.{nums[5:8]}/{nums[8:12]}-{nums[12:]}"
        )

    @staticmethod
    def format_phone(phone: str) -> str:
        nums = re.sub(r"\D", "", phone or "")
        if len(nums) == 10:
            return f"({nums[:2]}) {nums[2:6]}-{nums[6:]}"
        if len(nums) == 11:
            return f"({nums[:2]}) {nums[2:7]}-{nums[7:]}"
        return phone


# ─────────────────────────────── dates ─────────────────────────────────── #
class DateUtils:
    """Date/time helpers."""

    @staticmethod
    def format(date_obj: Union[date, datetime], fmt: str = "%d/%m/%Y") -> str:
        return date_obj.strftime(fmt) if date_obj else ""

    @staticmethod
    def parse(date_str: str, fmt: str = "%d/%m/%Y") -> Optional[date]:
        try:
            return datetime.strptime(date_str, fmt).date() if date_str else None
        except ValueError:
            return None

    # business‑day handling
    @staticmethod
    def add_business_days(start: date, days: int) -> date:
        current, added = start, 0
        while added < days:
            current += timedelta(days=1)
            if current.weekday() < 5:
                added += 1
        return current

    @staticmethod
    def age(birth: date, ref: Optional[date] = None) -> int:
        if not birth:
            return 0
        ref = ref or date.today()
        years = ref.year - birth.year
        if (ref.month, ref.day) < (birth.month, birth.day):
            years -= 1
        return years

    @staticmethod
    def quarter(d: Union[date, datetime]) -> int:
        return 0 if not d else (d.month - 1) // 3 + 1

    @staticmethod
    def week_range(d: Union[date, datetime]) -> tuple[Optional[date], Optional[date]]:
        if not d:
            return None, None
        if isinstance(d, datetime):
            d = d.date()
        start = d - timedelta(days=d.weekday())
        return start, start + timedelta(days=6)

    @staticmethod
    def is_business_day(d: Union[date, datetime]) -> bool:
        return bool(d and d.weekday() < 5)


# ─────────────────────────────── numbers ───────────────────────────────── #
class NumberUtils:
    """Numeric helpers (currency, percentages, sizes…)."""

    # currency
    @staticmethod
    def format_currency(val: Union[int, float, Decimal], cur: str = "BRL") -> str:
        if val is None:
            return ""
        if cur == "BRL":
            return f"U$ {val:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
        return f"{val:,.2f}"

    @staticmethod
    def parse_currency(s: str) -> Optional[Decimal]:
        if not s:
            return None
        clean = re.sub(r"[U$\s]", "", s).replace(",", ".")
        try:
            return Decimal(clean)
        except Exception:  # noqa: BLE001
            return None

    @staticmethod
    def round_currency(val: Union[int, float, Decimal], places: int = 2) -> Decimal:
        if val is None:
            return Decimal("0")
        return Decimal(str(val)).quantize(Decimal(f"1.{'0'*places}"), ROUND_HALF_UP)

    # percentage
    @staticmethod
    def format_percentage(val: Union[int, float, Decimal], places: int = 2) -> str:
        return "" if val is None else f"{float(val) * 100:.{places}f}%"

    @staticmethod
    def calc_percentage(part: Union[int, float], total: Union[int, float]) -> float:
        return 0.0 if not total else float(part) / float(total)

    # misc
    @staticmethod
    def format_file_size(bytes_: int) -> str:
        if bytes_ == 0:
            return "0 B"
        units = ["B", "KB", "MB", "GB", "TB"]
        size, idx = float(bytes_), 0
        while size >= 1024 and idx < len(units) - 1:
            size /= 1024
            idx += 1
        return f"{size:.1f} {units[idx]}"

    @staticmethod
    def is_number(val: Any) -> bool:
        try:
            float(val)
            return True
        except (TypeError, ValueError):
            return False

    @staticmethod
    def clamp(val: Union[int, float], mn: Union[int, float], mx: Union[int, float]):
        return max(mn, min(val, mx))


# ─────────────────────────────── dicts ─────────────────────────────────── #
class DictUtils:
    """Dictionary helpers (deep‑merge, flatten, filtering)."""

    @staticmethod
    def deep_merge(a: Dict[str, Any], b: Dict[str, Any]) -> Dict[str, Any]:
        res = a.copy()
        for k, v in b.items():
            if k in res and isinstance(res[k], dict) and isinstance(v, dict):
                res[k] = DictUtils.deep_merge(res[k], v)
            else:
                res[k] = v
        return res

    @staticmethod
    def flatten(nested: Dict[str, Any], sep: str = ".") -> Dict[str, Any]:
        def _flatten(obj, parent=""):
            if isinstance(obj, dict):
                accum: Dict[str, Any] = {}
                for k, v in obj.items():
                    new_key = f"{parent}{sep}{k}" if parent else k
                    accum.update(_flatten(v, new_key))
                return accum
            return {parent: obj}

        return _flatten(nested)

    @staticmethod
    def filter(data: Dict[str, Any], allowed: List[str]) -> Dict[str, Any]:
        return {k: v for k, v in data.items() if k in allowed}

    @staticmethod
    def remove_none(data: Dict[str, Any]) -> Dict[str, Any]:
        return {k: v for k, v in data.items() if v is not None}