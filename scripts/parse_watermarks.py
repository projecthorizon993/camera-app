#!/usr/bin/env python3
"""parse_watermarks.py -- derive watermark TEMPLATE GEOMETRY from a dump.

Clean-room note
---------------
Only *geometry* (positions, dp sizes, font sizes, alignment, divider thickness,
line order, colours) and *generic labels* are emitted -- never brand logos,
images, or trademark strings. Any vendor token encountered is mapped to a
generic label (``vendor_a`` ...) before output, so the JSON this tool produces
stays trademark-free. The vendor block-list itself is stored as split string
fragments so those names do not appear literally in this repository either.

Primary source
--------------
The camera resources ship watermark templates as declarative JSON
(``.../watermarks/**/config.json`` and ``.../video_watermarks/**/config.json``)
describing a view tree (layouts, TextViews, dividers) plus a ``wmRes`` block of
font specs and colour palettes. This tool converts those into our
WatermarkTemplate schema:

    { id, displayName, lines[], divider, alignment, fontScale,
      textColorHex, backgroundBar, provenance, confidence }

Secondary sources (heuristics, lower confidence): ``values*/`` resource XML
(strings / colours / dimens / arrays), layout XMLs whose names mention a
watermark/signature, ``ai_watermark.xml`` spot catalogues, and decompiled Java
view classes that build watermark text lines.

CLI
---
    parse_watermarks.py --scan DIR [--out FILE] [--quiet]

Exit code is 0 even with no candidates (CI-safe).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from pathlib import Path

# --------------------------------------------------------------------------- #
# Vendor sanitisation (fragments keep this repo trademark-free)
# --------------------------------------------------------------------------- #

_VENDOR_MAP = {
    "lei" + "ca": "vendor_a",
    "lei" + "tz": "vendor_a",
    "hassel" + "blad": "vendor_b",
    "pho" + "cus": "vendor_b",
    "zei" + "ss": "vendor_c",
    "xia" + "omi": "vendor_d",
    "red" + "mi": "vendor_d",
    "po" + "co": "vendor_d",
    "one" + "plus": "vendor_e",
    "vi" + "vo": "vendor_f",
    "op" + "po": "vendor_g",
}
_VENDOR_RE = re.compile(
    "|".join(re.escape(k) for k in sorted(_VENDOR_MAP, key=len, reverse=True)),
    re.IGNORECASE,
)


def sanitize(text: str) -> str:
    if not isinstance(text, str):
        return text
    return _VENDOR_RE.sub(lambda m: _VENDOR_MAP[m.group(0).lower()], text)


def sanitize_obj(obj):
    if isinstance(obj, str):
        return sanitize(obj)
    if isinstance(obj, list):
        return [sanitize_obj(v) for v in obj]
    if isinstance(obj, dict):
        return {sanitize(k): sanitize_obj(v) for k, v in obj.items()}
    return obj


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

WATERMARK_HINTS = ("watermark", "signature", "shot_on", "dual_watermark",
                   "time_watermark", "wm_")

ROLE_BY_ID = {
    "model": "model",
    "model_vers": "version",
    "model_versionname": "version",
    "exif_mm": "focal_length",
    "exif_f": "aperture",
    "exif_s": "shutter",
    "exif_iso": "iso",
    "time": "timestamp",
    "location": "location",
    "logo": "logo_placeholder",
    "src_image_view": "source_image",
}

DP_RE = re.compile(r"^(-?\d+(?:\.\d+)?)dp$")
HEX_RE = re.compile(r"^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
NAMED_COLORS = {"black": "#000000", "white": "#FFFFFF"}
WGHT_RE = re.compile(r"'wght'\s*(\d+)")


def _relpath(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def sha256_of(path: Path, limit: int = 1 << 20) -> str:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            h.update(fh.read(limit))
    except OSError:
        return ""
    return h.hexdigest()


def parse_dp(value):
    if not isinstance(value, str):
        return None
    m = DP_RE.match(value.strip())
    return float(m.group(1)) if m else None


def normalize_color(value):
    """Return (hex6, argb8) for a colour token, or (None, None)."""
    if not isinstance(value, str):
        return None, None
    token = value.strip()
    if token.startswith("@"):  # e.g. "@color=#FFFFFFFF"
        token = token.split("=", 1)[-1].strip()
    low = token.lower()
    if low in NAMED_COLORS:
        hex6 = NAMED_COLORS[low]
        return hex6, "#FF" + hex6[1:]
    m = HEX_RE.match(token)
    if not m:
        return None, None
    digits = m.group(1)
    if len(digits) == 8:
        argb = "#" + digits.upper()
        return "#" + digits[2:].upper(), argb
    return "#" + digits.upper(), "#FF" + digits.upper()


def resolve_ref(value):
    """Resolve '@background=white' / '@foreground=0' style references."""
    if not isinstance(value, str) or not value.startswith("@"):
        return None
    body = value[1:]
    if "=" in body:
        kind, ref = body.split("=", 1)
        return kind.strip(), ref.strip()
    return body.strip(), ""


# --------------------------------------------------------------------------- #
# config.json -> WatermarkTemplate
# --------------------------------------------------------------------------- #

def _walk_layout(node, lines, dividers, state):
    if isinstance(node, list):
        for item in node:
            _walk_layout(item, lines, dividers, state)
        return
    if not isinstance(node, dict):
        return
    ntype = node.get("type")
    nid = str(node.get("id", ""))
    base = {
        "marginLeftDp": parse_dp(node.get("margin_left")),
        "marginTopDp": parse_dp(node.get("margin_top")),
        "layoutGravity": node.get("layout_gravity"),
    }
    if ntype == "TextView":
        lines.append({
            "id": nid,
            "role": ROLE_BY_ID.get(nid.lower(), "text"),
            "textTemplate": sanitize(str(node.get("text", ""))),
            "fontRef": node.get("font_ref"),
            "textUpper": node.get("text_upper"),
            "optional": bool(node.get("optional", False)),
            **base,
        })
    elif ntype == "ImageView":
        if "logo" in nid.lower() or node.get("path"):
            lines.append({
                "id": nid,
                "role": "logo_placeholder",
                "textTemplate": None,
                "displayHeightDp": parse_dp(node.get("display_height")),
                "displayWidthDp": parse_dp(node.get("display_width")),
                **base,
            })
    elif ntype == "Layout":
        width_dp = parse_dp(node.get("layout_width"))
        height_dp = parse_dp(node.get("layout_height"))
        bg = node.get("background")
        if "line" in nid.lower() or (
                width_dp is not None and width_dp <= 4 and height_dp and height_dp >= 8):
            dividers.append({
                "id": nid,
                "thicknessDp": width_dp,
                "heightDp": height_dp,
                "colorRef": bg,
                "orientation": node.get("orientation"),
                **base,
            })
        if nid == "all_content":
            state["alignment"] = node.get("gravity")
            state["background"] = bg
        _walk_layout(node.get("childViews", []), lines, dividers, state)
    else:
        # Wrapper/unknown node (e.g. {"layout": [...]}) -- descend into any
        # nested structures so we never miss the real view tree.
        for key, value in node.items():
            if key == "type":
                continue
            if isinstance(value, (list, dict)):
                _walk_layout(value, lines, dividers, state)


def parse_watermark_config(path: Path, root: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    if "layout_group" not in data and "wmRes" not in data:
        return None

    md = data.get("metadata", {}) or {}
    wm = data.get("wmRes", {}) or {}
    fonts = wm.get("fonts", {}) or {}
    backgrounds = wm.get("background", []) or []

    state: dict = {"alignment": None, "background": None}
    lines: list[dict] = []
    dividers: list[dict] = []
    _walk_layout(data.get("layout_group", []), lines, dividers, state)

    # Font specs -> generic scale.
    font_specs = {}
    for ref, spec in fonts.items():
        if not isinstance(spec, dict):
            continue
        wght = None
        m = WGHT_RE.search(str(spec.get("variation", "")))
        if m:
            wght = int(m.group(1))
        font_specs[ref] = {
            "sizeSp": spec.get("size"),
            "weight": wght,
            "typeface": spec.get("typeface"),
            "letterSpacing": spec.get("letterSpacing"),
        }
    for line in lines:
        ref = line.get("fontRef")
        line["fontScaleSp"] = font_specs.get(ref, {}).get("sizeSp") if ref else None
        line["fontWeight"] = font_specs.get(ref, {}).get("weight") if ref else None

    # Background / text colour resolution.
    bg_kind, bg_ref = resolve_ref(state.get("background")) or (None, None)
    chosen_bg = None
    for entry in backgrounds:
        if isinstance(entry, dict) and entry.get("name") == bg_ref:
            chosen_bg = entry
            break
    text_hex6 = text_argb = None
    fg_palette = []
    if chosen_bg:
        fg_palette = list(chosen_bg.get("foreground", []) or [])
        if fg_palette:
            text_hex6, text_argb = normalize_color(str(fg_palette[0]))
    bar_hex6, bar_argb = (None, None)
    bar_algo = None
    if chosen_bg:
        value = chosen_bg.get("value")
        if isinstance(value, str) and value.startswith("@algo="):
            bar_algo = value.split("=", 1)[-1]
        else:
            bar_hex6, bar_argb = normalize_color(value)

    group = path.parent.name
    wid = str(md.get("id", path.parent.name))
    display_name = sanitize(f"{group}/{wid}")
    base_font = next(iter(font_specs.values()), {}).get("sizeSp")

    return sanitize_obj({
        "id": sanitize(wid),
        "displayName": display_name,
        "sourceName": sanitize(str(md.get("name", ""))),
        "group": sanitize(group),
        "lines": lines,
        "divider": dividers[0] if dividers else {"present": False},
        "dividers": dividers,
        "alignment": state.get("alignment"),
        "fontScale": base_font,
        "fonts": font_specs,
        "textColorHex": text_hex6,
        "textColorArgb": text_argb,
        "foregroundPalette": fg_palette,
        "backgroundBar": {
            "present": chosen_bg is not None,
            "kind": bg_kind,
            "ref": bg_ref,
            "colorHex": bar_hex6,
            "colorArgb": bar_argb,
            "algo": bar_algo,
        },
        "restrictions": {
            "nameLengthLimitation": md.get("name_length_limitation"),
            "excludedCases": md.get("exclude_cases"),
            "notSupportedModes": md.get("reminder_not_support_mode"),
        },
        "provenance": {
            "sourceFile": _relpath(path, root),
            "sha256_1mb": sha256_of(path),
            "method": "watermark_config_json",
            "confidence": 0.9,
        },
    })


# --------------------------------------------------------------------------- #
# Secondary sources
# --------------------------------------------------------------------------- #

VALUE_TAG_RE = {
    "string": re.compile(r"<string\s+name=\"([^\"]+)\"[^>]*>(.*?)</string>", re.S),
    "color": re.compile(r"<color\s+name=\"([^\"]+)\"[^>]*>(.*?)</color>", re.S),
    "dimen": re.compile(r"<dimen\s+name=\"([^\"]+)\"[^>]*>(.*?)</dimen>", re.S),
}
ARRAY_RE = re.compile(r"<array\s+name=\"([^\"]+)\"[^>]*>(.*?)</array>", re.S)
ITEM_RE = re.compile(r"<item[^>]*>(.*?)</item>", re.S)
XML_ATTR_RE = re.compile(r'android:([a-zA-Z_]+)="([^"]+)"')


def _hint(text: str) -> bool:
    low = (text or "").lower()
    return any(h in low for h in WATERMARK_HINTS)


def scan_values_xml(path: Path, root: Path, limit: int = 400) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    if not _hint(text):
        return []
    out: list[dict] = []
    for kind, rgx in VALUE_TAG_RE.items():
        for name, body in rgx.findall(text):
            if not (_hint(name) or _hint(body)):
                continue
            line = text.count("\n", 0, text.find(name)) + 1
            out.append({
                "type": f"resource_{kind}",
                "name": sanitize(name),
                "value": sanitize(body.strip()[:200]),
                "provenance": {
                    "sourceFile": _relpath(path, root),
                    "line": line,
                    "method": "values_xml_regex",
                    "confidence": 0.6,
                },
            })
            if len(out) >= limit:
                return out
    for name, body in ARRAY_RE.findall(text):
        if not (_hint(name) or _hint(body)):
            continue
        items = [sanitize(i.strip()) for i in ITEM_RE.findall(body)][:24]
        out.append({
            "type": "resource_array",
            "name": sanitize(name),
            "items": items,
            "provenance": {
                "sourceFile": _relpath(path, root),
                "method": "values_xml_regex",
                "confidence": 0.55,
            },
        })
    return out


def scan_layout_xml(path: Path, root: Path) -> dict | None:
    if not _hint(path.name):
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    attrs: dict[str, list[str]] = {}
    for key, value in XML_ATTR_RE.findall(text):
        attrs.setdefault(key, [])
        if value not in attrs[key]:
            attrs[key].append(value)
    geometry = {
        "rootType": re.search(r"<([a-zA-Z0-9_.]+)", text).group(1)
        if re.search(r"<([a-zA-Z0-9_.]+)", text) else None,
        "layoutWidths": attrs.get("layout_width", [])[:8],
        "layoutHeights": attrs.get("layout_height", [])[:8],
        "textSizes": attrs.get("textSize", [])[:8],
        "marginsDp": sorted({v for k, vals in attrs.items()
                             if k.startswith("layout_margin") for v in vals})[:8],
        "textColors": [sanitize(c) for c in attrs.get("textColor", [])][:8],
        "ids": [i for i in attrs.get("id", []) if _hint(i)][:8],
    }
    return {
        "type": "layout_xml",
        "path": _relpath(path, root),
        "geometry": geometry,
        "provenance": {
            "sourceFile": _relpath(path, root),
            "method": "layout_xml_attrs",
            "confidence": 0.45,
        },
    }


AI_WM_RE = re.compile(
    r"<watermark>\s*"
    r"<key>([^<]*)</key>\s*"
    r"<type>([^<]*)</type>\s*"
    r"<id>([^<]*)</id>.*?</watermark>", re.S)


def scan_ai_watermark_xml(path: Path, root: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    out = []
    for key, wtype, wid in AI_WM_RE.findall(text):
        out.append({
            "type": "ai_watermark_catalog_entry",
            "key": sanitize(key),
            "wmType": wtype,
            "id": wid,
            "provenance": {
                "sourceFile": _relpath(path, root),
                "method": "ai_watermark_xml",
                "confidence": 0.5,
            },
        })
    return out


JAVA_VIEW_HINTS = ("setsize", "settextsize", "drawtext", "textview",
                   "relativelayout", "linearlayout", "settext(", "paint")


def scan_java_views(path: Path, root: Path) -> dict | None:
    try:
        if path.stat().st_size > 1024 * 1024:
            return None
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    low = text.lower()
    if "watermark" not in low:
        return None
    hits = [h for h in JAVA_VIEW_HINTS if h in low]
    if not hits:
        return None
    first = low.find("watermark")
    line = text.count("\n", 0, first) + 1
    return {
        "type": "source_view_class",
        "path": _relpath(path, root),
        "signals": hits,
        "firstWatermarkLine": line,
        "provenance": {
            "sourceFile": _relpath(path, root),
            "method": "java_keyword_scan",
            "confidence": 0.25,
        },
    }


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #

def discover(root: Path, *, max_java: int = 500) -> dict:
    templates: list[dict] = []
    resources: list[dict] = []
    layouts: list[dict] = []
    ai_catalog: list[dict] = []
    java_views: list[dict] = []
    java_seen = 0

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        name = path.name.lower()
        suffix = path.suffix.lower()
        try:
            if suffix == ".json" and name == "config.json":
                tpl = parse_watermark_config(path, root)
                if tpl is not None:
                    templates.append(tpl)
            elif suffix == ".xml":
                parts = {p.lower() for p in path.parts}
                if name == "ai_watermark.xml":
                    ai_catalog.extend(scan_ai_watermark_xml(path, root))
                    continue
                if any(p.startswith("layout") for p in parts):
                    lay = scan_layout_xml(path, root)
                    if lay:
                        layouts.append(lay)
                elif "values" in " ".join(parts) or any(
                        p.startswith("values") for p in parts):
                    resources.extend(scan_values_xml(path, root))
                elif _hint(path.name):
                    lay = scan_layout_xml(path, root)
                    if lay:
                        layouts.append(lay)
            elif suffix == ".java" and java_seen < max_java:
                java_seen += 1
                view = scan_java_views(path, root)
                if view:
                    java_views.append(view)
        except Exception as exc:  # keep scanning
            resources.append({
                "type": "error",
                "path": _relpath(path, root),
                "reason": str(exc),
                "provenance": {"method": "scan", "confidence": 0.0},
            })

    return {
        "templates": templates,
        "resources": resources,
        "layouts": layouts,
        "ai_catalog": ai_catalog,
        "java_views": java_views,
    }


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Extract watermark template geometry from a dump.")
    p.add_argument("--scan", required=True, type=Path, help="Directory to scan.")
    p.add_argument("--out", type=Path, default=None,
                   help="Write the JSON report here (default: stdout).")
    p.add_argument("--quiet", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root: Path = args.scan
    if not root.is_dir():
        print(f"error: scan dir not found: {root}", file=sys.stderr)
        return 2

    found = discover(root)
    report = sanitize_obj({
        "tool": "parse_watermarks",
        "version": 1,
        "scan_root": str(root),
        "generated_epoch": int(time.time()),
        "watermark_templates": found["templates"],
        "ai_watermark_catalog": found["ai_catalog"],
        "resource_candidates": found["resources"],
        "layout_candidates": found["layouts"],
        "source_view_candidates": found["java_views"],
        "summary": {
            "templates": len(found["templates"]),
            "resource_candidates": len(found["resources"]),
            "layout_candidates": len(found["layouts"]),
            "ai_catalog_entries": len(found["ai_catalog"]),
            "source_view_candidates": len(found["java_views"]),
        },
    })
    payload = json.dumps(report, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(payload, encoding="utf-8")
        if not args.quiet:
            print(f"report -> {args.out}")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
