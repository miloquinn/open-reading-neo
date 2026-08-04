from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlparse


@dataclass(frozen=True)
class ReadingSource:
    name: str
    url: str
    source_type: int
    raw: dict[str, Any]
    origin: str
    index: int

    @property
    def stable_key(self) -> str:
        return self.url or f"{self.origin}#{self.index}"

    @property
    def is_http_url(self) -> bool:
        parsed = urlparse(self.url.split("#", 1)[0])
        return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


@dataclass
class ParseResult:
    sources: list[ReadingSource] = field(default_factory=list)
    source_urls: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    duplicates: int = 0


def load_file(path: str | Path) -> ParseResult:
    source_path = Path(path)
    try:
        payload = json.loads(source_path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        return ParseResult(errors=[f"{source_path.name}: {error}"])
    return parse_payload(payload, origin=str(source_path))


def parse_payload(payload: Any, *, origin: str = "<memory>") -> ParseResult:
    result = ParseResult()
    candidates = list(_source_candidates(payload, result))
    by_key: dict[str, ReadingSource] = {}
    for index, raw in enumerate(candidates):
        if not isinstance(raw, dict):
            result.errors.append(f"{origin}[{index}]: source must be an object")
            continue
        name = _text(raw.get("bookSourceName"))
        url = _text(raw.get("bookSourceUrl"))
        if not name:
            result.errors.append(f"{origin}[{index}]: missing bookSourceName")
            continue
        source = ReadingSource(
            name=name,
            url=url,
            source_type=_integer(raw.get("bookSourceType")),
            raw=dict(raw),
            origin=origin,
            index=index,
        )
        if source.stable_key in by_key:
            result.duplicates += 1
            by_key.pop(source.stable_key)
        by_key[source.stable_key] = source
    result.sources.extend(by_key.values())
    return result


def _source_candidates(payload: Any, result: ParseResult) -> Iterable[Any]:
    if isinstance(payload, list):
        yield from payload
        return
    if not isinstance(payload, dict):
        result.errors.append("payload must be an object or array")
        return
    if "bookSourceUrl" in payload or "bookSourceName" in payload:
        yield payload
        return
    nested_urls = payload.get("sourceUrls")
    if isinstance(nested_urls, list):
        result.source_urls.extend(
            value.strip() for value in nested_urls if isinstance(value, str) and value.strip()
        )
    for key in ("sources", "bookSources", "data", "items"):
        nested = payload.get(key)
        if isinstance(nested, list):
            yield from nested
            return
    if not result.source_urls:
        result.errors.append("object does not contain a reading source or source list")


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _integer(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return 0
