from __future__ import annotations

from collections import Counter
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
from typing import Any, Iterable

from .parser import ReadingSource, load_file


FEATURES: dict[str, re.Pattern[str]] = {
    "javascript": re.compile(r"@js:|<js>", re.I),
    "webview": re.compile(
        r"java\.webview\s*\(|['\"]?webview['\"]?\s*:\s*true|"
        r"['\"]?webjs['\"]?\s*:\s*['\"][^'\"]+",
        re.I,
    ),
    "xpath": re.compile(r"@xpath:|(?<!:)//(?:[a-z*]|\*)", re.I),
    "jsonpath": re.compile(r"@json:|\$\. |\$\[|\$\.\.|\$\.", re.I | re.X),
    "css": re.compile(r"@css:|(?:^|[@\n])(?:[.#\[]|class\.|id\.|tag\.)", re.I),
    "regex": re.compile(r"##|(?:^|\n):[^/]"),
    "interleave": re.compile(r"%%"),
    "state": re.compile(r"@put:|@get:|java\.(?:put|get)\s*\(", re.I),
    "post": re.compile(r"['\"]?method['\"]?\s*:\s*['\"]?post|java\.post\s*\(", re.I),
    "cookie": re.compile(r"enabledcookiejar|cookie\.|getcookie|setcookie", re.I),
    "login": re.compile(
        r"source\.(?:get|put|remove)login|login(?:info|header)", re.I
    ),
    "crypto": re.compile(r"\b(?:md5|sha\d*|aes|des|rsa|hmac|base64)\b", re.I),
    "java_dom": re.compile(r"java\.(?:getelements|getelement|getstring|getstringlist)\s*\(", re.I),
    "browser_interaction": re.compile(r"startbrowser|verification|captcha|验证码|验证", re.I),
    "head": re.compile(r"java\.head\s*\(|['\"]?method['\"]?\s*:\s*['\"]?head", re.I),
    "cache_api": re.compile(r"\bcache\.[A-Za-z_][A-Za-z0-9_]*\s*\("),
    "shared_script": re.compile(r"['\"]jsLib['\"]\s*:"),
}

SCRIPT_API = re.compile(
    r"\b(java|cookie|source)\.([A-Za-z_][A-Za-z0-9_]*)\b"
)
JAVA_COLLECTION_API = re.compile(r"\.(size|get|isEmpty|toArray)\s*\(")

OPEN_READING_STATUS = {
    "javascript": "supported-native",
    "webview": "supported-android",
    "xpath": "supported-subset",
    "jsonpath": "supported",
    "css": "supported",
    "regex": "supported",
    "interleave": "supported",
    "state": "supported-subset",
    "post": "supported",
    "cookie": "supported-session",
    "login": "partial",
    "crypto": "supported-subset",
    "java_dom": "supported-subset",
    "browser_interaction": "unsupported",
    "head": "supported",
    "cache_api": "supported-session",
    "shared_script": "supported-inline",
}


@dataclass(frozen=True)
class FileAudit:
    file: str
    parsed: int
    duplicates: int
    errors: int
    invalid_urls: int
    source_types: dict[str, int]
    features: dict[str, int]
    capabilities: dict[str, int]
    core_reading: dict[str, int]
    compatibility: dict[str, int]
    script_apis: dict[str, int]
    java_collection_apis: dict[str, int]


def audit_files(paths: Iterable[str | Path]) -> dict[str, Any]:
    audits: list[FileAudit] = []
    totals = Counter()
    feature_totals = Counter()
    script_api_totals = Counter()
    collection_api_totals = Counter()
    for path in paths:
        parsed = load_file(path)
        audit = _audit(Path(path), parsed.sources, parsed.duplicates, len(parsed.errors))
        audits.append(audit)
        totals.update(
            parsed=audit.parsed,
            duplicates=audit.duplicates,
            errors=audit.errors,
            invalid_urls=audit.invalid_urls,
        )
        feature_totals.update(audit.features)
        script_api_totals.update(audit.script_apis)
        collection_api_totals.update(audit.java_collection_apis)
    return {
        "files": [asdict(audit) for audit in audits],
        "totals": dict(totals),
        "feature_totals": dict(feature_totals),
        "script_api_totals": dict(script_api_totals),
        "java_collection_api_totals": dict(collection_api_totals),
        "support": OPEN_READING_STATUS,
    }


def render_markdown(report: dict[str, Any]) -> str:
    totals = report["totals"]
    lines = [
        "# Reading source compatibility audit",
        "",
        "> Offline structural audit. It does not execute scripts, contact sites, or expose auth values.",
        "",
        f"Parsed **{totals.get('parsed', 0)}** sources from **{len(report['files'])}** files; "
        f"duplicates: **{totals.get('duplicates', 0)}**; parse errors: **{totals.get('errors', 0)}**; "
        f"invalid/empty URLs: **{totals.get('invalid_urls', 0)}**.",
        "",
        "## Files",
        "",
        "| File | Sources | Invalid URLs | Supported | Partial | Unsupported |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for item in report["files"]:
        compatibility = item["compatibility"]
        core_reading = item["core_reading"]
        lines.append(
            f"| {item['file']} | {item['parsed']} | {item['invalid_urls']} | "
            f"{compatibility.get('supported', 0)} | {compatibility.get('partial', 0)} | "
            f"{compatibility.get('unsupported', 0)} |"
        )
    core_ready = sum(
        item["core_reading"].get("ready", 0) for item in report["files"]
    )
    parsed_total = totals.get("parsed", 0)
    core_rate = core_ready / parsed_total * 100 if parsed_total else 0
    lines.extend(
        [
            "",
            "## Core reading chain",
            "",
            f"**{core_ready} / {parsed_total} ({core_rate:.1f}%)** sources have a text type, "
            "valid HTTP(S) URL, search entry, catalog rules, and content rules. This is an "
            "offline structural readiness rate, not a live-site success rate.",
            "",
            "## Feature dependency totals",
            "",
            "| Feature | Sources | Open Reading status |",
            "|---|---:|---|",
        ]
    )
    for feature, count in sorted(
        report["feature_totals"].items(), key=lambda item: (-item[1], item[0])
    ):
        lines.append(f"| `{feature}` | {count} | {report['support'][feature]} |")
    lines.extend(
        [
            "",
            "## Script API occurrences",
            "",
            "| API | Occurrences |",
            "|---|---:|",
        ]
    )
    for api, count in sorted(
        report["script_api_totals"].items(), key=lambda item: (-item[1], item[0])
    ):
        lines.append(f"| `{api}` | {count} |")
    lines.extend(
        [
            "",
            "## Java collection compatibility occurrences",
            "",
            "| Method | Occurrences |",
            "|---|---:|",
        ]
    )
    for api, count in sorted(
        report["java_collection_api_totals"].items(),
        key=lambda item: (-item[1], item[0]),
    ):
        lines.append(f"| `{api}()` | {count} |")
    return "\n".join(lines) + "\n"


def render_json(report: dict[str, Any]) -> str:
    return json.dumps(report, ensure_ascii=False, indent=2) + "\n"


def _audit(
    path: Path, sources: list[ReadingSource], duplicates: int, errors: int
) -> FileAudit:
    source_types = Counter(str(source.source_type) for source in sources)
    features = Counter()
    capabilities = Counter()
    core_reading = Counter()
    compatibility = Counter()
    script_apis = Counter()
    java_collection_apis = Counter()
    invalid_urls = 0
    for source in sources:
        if not source.is_http_url:
            invalid_urls += 1
        text = _safe_serialized(source.raw)
        script_apis.update(
            f"{match.group(1)}.{match.group(2)}" for match in SCRIPT_API.finditer(text)
        )
        java_collection_apis.update(
            match.group(1) for match in JAVA_COLLECTION_API.finditer(text)
        )
        matched = _features_for_source(source)
        features.update(matched)
        for capability, keys in {
            "search": ("searchUrl", "ruleSearch"),
            "explore": ("exploreUrl", "ruleExplore"),
            "detail": ("ruleBookInfo",),
            "toc": ("ruleToc",),
            "content": ("ruleContent",),
        }.items():
            if any(source.raw.get(key) for key in keys):
                capabilities[capability] += 1
        core_reading[_core_reading_status(source)] += 1
        compatibility[_compatibility(source, matched)] += 1
    return FileAudit(
        file=path.name,
        parsed=len(sources),
        duplicates=duplicates,
        errors=errors,
        invalid_urls=invalid_urls,
        source_types=dict(sorted(source_types.items())),
        features=dict(sorted(features.items())),
        capabilities=dict(sorted(capabilities.items())),
        core_reading=dict(sorted(core_reading.items())),
        compatibility=dict(sorted(compatibility.items())),
        script_apis=dict(sorted(script_apis.items())),
        java_collection_apis=dict(sorted(java_collection_apis.items())),
    )


def _compatibility(source: ReadingSource, features: set[str]) -> str:
    if source.source_type != 0:
        return "unsupported"
    if not source.is_http_url or not source.raw.get("ruleContent"):
        return "unsupported"
    if "browser_interaction" in features or "login" in features or "webview" in features:
        return "partial"
    if any(OPEN_READING_STATUS[name].endswith("subset") for name in features):
        return "partial"
    return "supported"


def _core_reading_status(source: ReadingSource) -> str:
    raw = source.raw
    ready = (
        source.source_type == 0
        and source.is_http_url
        and bool(raw.get("searchUrl"))
        and bool(raw.get("ruleSearch"))
        and bool(raw.get("ruleToc"))
        and bool(raw.get("ruleContent"))
    )
    return "ready" if ready else "incomplete"


def _features_for_source(source: ReadingSource) -> set[str]:
    """Find capability dependencies without counting empty template fields."""
    raw = source.raw
    text = _safe_serialized(raw)
    matched = set()

    def values(*keys: str) -> list[str]:
        result: list[str] = []
        for key in keys:
            value = raw.get(key)
            if isinstance(value, str) and value.strip():
                result.append(value)
            elif isinstance(value, dict):
                result.append(_safe_serialized(value))
        return result

    nonempty_text = "\n".join(
        values(
            "searchUrl",
            "exploreUrl",
            "loginUrl",
            "loginUi",
            "loginCheckJs",
            "webJs",
            "jsLib",
            "header",
            "cookie",
            "ruleSearch",
            "ruleExplore",
            "ruleBookInfo",
            "ruleToc",
            "ruleContent",
        )
    )
    for name, pattern in FEATURES.items():
        haystack = nonempty_text if name in {
            "login",
            "webview",
            "shared_script",
            "cookie",
            "javascript",
            "xpath",
            "jsonpath",
            "css",
            "regex",
            "interleave",
            "state",
            "post",
            "crypto",
            "java_dom",
            "browser_interaction",
            "head",
            "cache_api",
        } else text
        if pattern.search(haystack):
            matched.add(name)

    if values("loginUrl", "loginUi", "loginCheckJs"):
        matched.add("login")
    if values("webJs"):
        matched.add("webview")
    if values("jsLib"):
        matched.add("shared_script")
    if raw.get("enabledCookieJar") is True:
        matched.add("cookie")
    elif "cookie." not in nonempty_text.lower():
        matched.discard("cookie")
    return matched


def _safe_serialized(raw: dict[str, Any]) -> str:
    # Values are scanned only in memory and never returned by the auditor.
    return json.dumps(raw, ensure_ascii=False, separators=(",", ":"))
