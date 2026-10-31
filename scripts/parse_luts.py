#!/usr/bin/env python3
"""parse_luts.py -- find and decode colour-look (3D LUT) candidates in a dump.

Clean-room note
---------------
The tool reads a *dump/source tree* and emits only DERIVED, generic data:
  * ``--inventory`` mode: a JSON *report* (file, offset, dims guess, confidence);
  * extraction mode: a ``.cube`` (33^3 by default) plus a provenance sidecar.
No vendor image, blob or source is copied. Callers must keep ``--extract-dir``
outside the camera-app repo (or inside a git-ignored path) for real dumps; only
tiny self-derived samples belong in ``scripts/testdata``.

What it looks for
-----------------
1. ``.cube`` text LUTs (Adobe/Resolve format).
2. **Tiled 3D-LUT PNGs** (the primary target): a 3D LUT of size N stored as a
   grid of N x N tiles, ``cols = ceil(sqrt(N))`` wide, e.g.
   512x512 = 64^3 (8x8 tiles of 64px) and 64x64 = 16^3 (4x4 tiles of 16px).
   Decoding: tiles are laid out row-major; within a tile ``x -> R``, ``y -> G``
   and the tile index ``-> B`` (configurable via ``--tile-axis/--x-axis/--y-axis``).
   Emitted ``.cube`` is written in the spec order (red index fastest).
3. Binary float/half grids whose byte length matches an N^3 * 3 * {2,4} layout.
4. Java source numeric tables (large array initialisers) near colour keywords.
5. Opaque candidates (bad magic / high entropy) are FLAGGED and EXCLUDED with a
   reason rather than guessed at.

PNG decoding uses only the standard library (``zlib``) for 8-bit RGB/RGBA,
non-interlaced images, so extraction works even without OpenCV; 16-bit or
palette images fall back to OpenCV when available.

CLI
---
    parse_luts.py --scan DIR [--inventory] [--out REPORT.json]
                  [--extract-dir DIR] [--lut-size N] [--min-confidence F]
                  [--no-source] [--quiet]

Exit code is 0 even when no candidates are found (CI-safe).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import struct
import sys
import time
import zlib
from collections import Counter
from pathlib import Path

try:  # numpy is a runtime dependency but not needed for inventory mode.
    import numpy as np
except Exception:  # pragma: no cover - exercised only without numpy
    np = None

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

PNG_SIG = b"\x89PNG\r\n\x1a\n"
JPEG_SIG = b"\xff\xd8\xff"

IMAGE_SUFFIXES = {".png", ".tif", ".tiff", ".bmp", ".webp"}
SOURCE_SUFFIXES = {".java", ".kt", ".frag", ".glsl", ".vert", ".c", ".h", ".cpp"}

# LUT sizes we consider plausible, largest first (65 is odd-sized, 33/17 common).
LUT_SIZES = (65, 64, 33, 32, 17, 16, 8, 4)

# Names/dirs that hint at a colour-look payload.
LUT_NAME_HINTS = (
    "lut", "colour", "color", "colormap", "color_map", "gamut", "gmap",
    "curve", "tone", "film", "filter", "grade", "icc",
)
SOURCE_KEYWORDS = ("lut", "color", "colour", "filter", "tone", "curve",
                   "saturation", "contrast", "gamma", "transfer")

# Suspicious array lengths in decompiled sources (cubes and powers of two).
SUSPICIOUS_LENGTHS = {
    8 ** 3, 16 ** 3, 17 ** 3, 32 ** 3, 33 ** 3, 64 ** 3,
    256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
}

NUMBER_RE = re.compile(r"[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?[fFdDlL]?")
ARRAY_RE = re.compile(r"\{(?P<body>[^{}]{64,400000})\}")
FLOAT_ARRAY_HDR = re.compile(r"new\s+(?:float|double|int|long)\s*(?:\[\s*\])+\s*$")

MAX_SOURCE_FILE_BYTES = 2 * 1024 * 1024
MAX_SOURCE_FILES = 6000
MAX_SOURCE_CANDIDATES_PER_FILE = 6
ENTROPY_SAMPLE = 1 << 20  # 1 MiB


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

def _relpath(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def sniff_magic(path: Path) -> str:
    try:
        with open(path, "rb") as fh:
            head = fh.read(16)
    except OSError:
        return "unreadable"
    if head.startswith(PNG_SIG):
        return "png"
    if head.startswith(JPEG_SIG):
        return "jpeg"
    if head[:4] in (b"II*\x00", b"MM\x00*"):
        return "tiff"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return "unknown"


def png_dims(path: Path) -> tuple[int, int, int, int] | None:
    """Return (width, height, bit_depth, colour_type) from the IHDR, or None."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(33)
    except OSError:
        return None
    if not data.startswith(PNG_SIG) or data[12:16] != b"IHDR":
        return None
    width, height, depth, ctype = struct.unpack(">IIBB", data[16:26])
    return width, height, depth, ctype


def file_entropy(path: Path, sample: int = ENTROPY_SAMPLE) -> float:
    try:
        with open(path, "rb") as fh:
            data = fh.read(sample)
    except OSError:
        return 0.0
    if not data:
        return 0.0
    counts = Counter(data)
    n = len(data)
    ent = 0.0
    for c in counts.values():
        p = c / n
        ent -= p * math.log2(p)
    return ent


def sha256_of(path: Path, limit: int = 1 << 20) -> str:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            h.update(fh.read(limit))
    except OSError:
        return ""
    return h.hexdigest()


def guess_lut_from_dims(width: int, height: int) -> list[dict]:
    """Guess (N, tile-cols) for a square tiled-LUT image."""
    if width != height or width < 16:
        return []
    guesses: list[dict] = []

    def add(n: int, cols: int, conf: float, layout: str) -> None:
        if not any(g["lut_size"] == n for g in guesses):
            guesses.append({
                "lut_size": n, "tile_cols": cols,
                "tile_rows": math.ceil(n / cols),
                "layout": layout, "confidence": conf,
            })

    # Scheme A: near-square tile grid, cols = ceil(sqrt(N)).
    for n in LUT_SIZES:
        cols = math.ceil(math.sqrt(n))
        if n * cols == width:
            add(n, cols, 0.92, f"{cols}x{math.ceil(n / cols)} tiles of {n}px")
    # Scheme B: classic fixed 8-column layout (N = width / 8).
    if width % 8 == 0:
        n = width // 8
        if n in LUT_SIZES:
            add(n, 8, 0.88, f"8x{math.ceil(n / 8)} tiles of {n}px")
    return guesses


def guess_binary_grid(size_bytes: int) -> list[dict]:
    """Match a raw file size against N^3 * 3 * {2,4} bytes (half/float32)."""
    out: list[dict] = []
    for n in LUT_SIZES:
        cube = n ** 3
        for dtype, width in (("float16", 2), ("float32", 4)):
            expected = cube * 3 * width
            if abs(size_bytes - expected) <= 64:
                out.append({
                    "lut_size": n, "dtype": dtype,
                    "confidence": 0.5 if dtype == "float32" else 0.45,
                    "layout": "linear N^3 RGB",
                })
            # also tolerate 4-channel float variants
            expected4 = cube * 4 * width
            if abs(size_bytes - expected4) <= 64:
                out.append({
                    "lut_size": n, "dtype": dtype + "/rgba",
                    "confidence": 0.35,
                    "layout": "linear N^3 RGBA",
                })
    return out


# --------------------------------------------------------------------------- #
# PNG decoding (stdlib; RGB/RGBA 8-bit, non-interlaced)
# --------------------------------------------------------------------------- #

def decode_png_pixels(path: Path):
    """Decode an 8-bit RGB/RGBA/grey non-interlaced PNG to (w, h, channels, bytes).

    Returns None when the image uses an unsupported feature (interlacing,
    16-bit, palette) so the caller can fall back to OpenCV.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(PNG_SIG):
        return None
    pos = 8
    width = height = depth = ctype = None
    idat = bytearray()
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype_tag = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype_tag == b"IHDR":
            width, height, depth, ctype, comp, filt, interlace = struct.unpack(
                ">IIBBBBB", chunk)
            if interlace:
                return None
        elif ctype_tag == b"IDAT":
            idat += chunk
        elif ctype_tag == b"IEND":
            break
    if width is None or depth != 8 or ctype not in (0, 2, 6):
        return None
    channels = {0: 1, 2: 3, 6: 4}[ctype]
    stride = width * channels
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error:
        return None
    if len(raw) < height * (stride + 1):
        return None
    out = bytearray(height * stride)
    prev = bytearray(stride)
    src = 0
    for y in range(height):
        ftype = raw[src]
        src += 1
        line = bytearray(raw[src:src + stride])
        src += stride
        if ftype == 0:
            pass
        elif ftype == 1:
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 0xFF
        elif ftype == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif ftype == 3:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif ftype == 4:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = prev[x]
                c = prev[x - channels] if x >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    pr = a
                elif pb <= pc:
                    pr = b
                else:
                    pr = c
                line[x] = (line[x] + pr) & 0xFF
        else:
            return None
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return width, height, channels, bytes(out)


def load_image_rgb(path: Path):
    """Load an image as an (h, w, 3) uint8 numpy array, or None."""
    if np is None:
        return None
    decoded = decode_png_pixels(path)
    if decoded is not None:
        width, height, channels, pixels = decoded
        arr = np.frombuffer(pixels, dtype=np.uint8).reshape(height, width, channels)
        if channels == 1:
            arr = np.repeat(arr, 3, axis=2)
        return arr[:, :, :3]
    # Fallback: OpenCV (handles 16-bit / palette / TIFF).
    try:
        import cv2  # type: ignore
    except Exception:
        return None
    img = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if img is None:
        return None
    if img.ndim == 2:
        img = np.repeat(img[:, :, None], 3, axis=2)
    if img.shape[2] == 4:
        img = img[:, :, :3]
    if img.dtype != np.uint8:
        img = np.clip(img, 0, 255).astype(np.uint8)
    return img[:, :, :3]


# --------------------------------------------------------------------------- #
# 3D LUT assembly + .cube I/O
# --------------------------------------------------------------------------- #

def assemble_tiles_tiled(img, lut_size: int, tile_cols: int,
                         tile_axis: str = "b", x_axis: str = "r",
                         y_axis: str = "g"):
    """Assemble a tiled LUT image into an (N, N, N, 3) float32 grid in [0, 1].

    The returned ``lut[b, g, r]`` holds the output RGB for input grid index
    (r, g, b), matching the ``.cube`` ordering used by :func:`write_cube`.
    """
    if np is None:
        raise RuntimeError("numpy is required for LUT extraction")
    n = int(lut_size)
    cols = int(tile_cols)
    rows = math.ceil(n / cols)
    h, w = img.shape[0], img.shape[1]
    if h < rows * n or w < cols * n:
        raise ValueError(
            f"image {w}x{h} too small for {rows}x{cols} tiles of {n}px")

    lut = np.zeros((n, n, n, 3), dtype=np.float32)
    xx = np.tile(np.arange(n, dtype=np.intp), (n, 1))     # (n, n) column index
    yy = np.tile(np.arange(n, dtype=np.intp)[:, None], (1, n))
    for tile_idx in range(n):
        r = tile_idx // cols
        c = tile_idx % cols
        tile = img[r * n:(r + 1) * n, c * n:(c + 1) * n, :3].astype(np.float32)
        if tile.shape[0] != n or tile.shape[1] != n:
            raise ValueError("ragged tile at index %d" % tile_idx)
        grids = {
            "r": xx,
            "g": yy,
            "b": np.full((n, n), tile_idx, dtype=np.intp),
        }
        lut[grids[tile_axis], grids[y_axis], grids[x_axis]] = tile / 255.0
    return lut


def write_cube(lut, path: Path, title: str) -> None:
    """Write an (N, N, N, 3) float grid as a .cube file (red index fastest)."""
    n = lut.shape[0]
    if not np.issubdtype(lut.dtype, np.floating):
        lut = lut.astype(np.float32)
    lines = [
        f"# {title}",
        "# Generated by parse_luts.py (clean-room derived parameters; no vendor data).",
        "DOMAIN_MIN 0.0 0.0 0.0",
        "DOMAIN_MAX 1.0 1.0 1.0",
        f"LUT_3D_SIZE {n}",
    ]
    arr = np.clip(lut, 0.0, 1.0).reshape(-1, 3)
    lines.extend(f"{r:.6f} {g:.6f} {b:.6f}" for r, g, b in arr)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def read_cube(path: Path):
    """Parse a .cube file to (size, lut array). Returns (n, lut) or None."""
    if np is None:
        return None
    size = None
    values: list[tuple[float, float, float]] = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            upper = line.upper()
            if upper.startswith("LUT_3D_SIZE"):
                size = int(parts[1])
            elif upper.startswith(("DOMAIN_MIN", "DOMAIN_MAX", "TITLE")):
                continue
            elif upper.startswith("LUT_1D_SIZE"):
                return None
            else:
                try:
                    values.append((float(parts[0]), float(parts[1]), float(parts[2])))
                except (ValueError, IndexError):
                    continue
    if not size:
        return None
    expected = size ** 3
    if len(values) < expected:
        return None
    arr = np.asarray(values[:expected], dtype=np.float32).reshape(size, size, size, 3)
    return size, arr


# --------------------------------------------------------------------------- #
# Candidate scanning
# --------------------------------------------------------------------------- #

def _make_candidate(path: Path, root: Path, **fields) -> dict:
    cand = {
        "path": _relpath(path, root),
        "offset": 0,  # byte offset of the payload within the file, when known
        "type": "unknown",
        "size_bytes": None,
        "magic": None,
        "dims": None,
        "lut_size": None,
        "layout": None,
        "confidence": 0.0,
        "method": None,
        "excluded": False,
        "reason": None,
    }
    cand.update(fields)
    return cand


def scan_cube_file(path: Path, root: Path) -> dict:
    size = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            head = fh.read(4096)
    except OSError:
        head = ""
    for line in head.splitlines():
        if line.strip().upper().startswith("LUT_3D_SIZE"):
            try:
                size = int(line.split()[1])
            except (IndexError, ValueError):
                pass
            break
    return _make_candidate(
        path, root, type="cube", size_bytes=path.stat().st_size, magic="cube-text",
        lut_size=size, layout="cube 3D", confidence=0.99,
        method="cube_header", dims=None,
    )


def scan_image_file(path: Path, root: Path, name_hint: bool) -> list[dict]:
    magic = sniff_magic(path)
    size = path.stat().st_size
    out: list[dict] = []
    if magic == "png":
        dims = png_dims(path)
        if dims is None:
            return out
        w, h, depth, ctype = dims
        guesses = guess_lut_from_dims(w, h)
        if guesses:
            best = max(guesses, key=lambda g: g["confidence"])
            others = [g for g in guesses if g is not best]
            conf = best["confidence"] * (1.0 if name_hint else 0.85)
            out.append(_make_candidate(
                path, root, type="png_lut", size_bytes=size, magic="png",
                dims=[w, h], lut_size=best["lut_size"], layout=best["layout"],
                confidence=round(conf, 3), method="png_tiled_lut",
                bit_depth=depth, colour_type=ctype,
                alternatives=[{"lut_size": g["lut_size"], "layout": g["layout"]}
                              for g in others],
            ))
        elif name_hint:
            out.append(_make_candidate(
                path, root, type="png_unclassified", size_bytes=size, magic="png",
                dims=[w, h], confidence=0.15, method="png_dims",
                excluded=True, reason=f"square-ish PNG {w}x{h} not a known LUT layout",
            ))
        return out
    if magic in ("jpeg", "webp", "tiff"):
        if name_hint:
            out.append(_make_candidate(
                path, root, type="image_not_lut", size_bytes=size, magic=magic,
                confidence=0.05, method="magic", excluded=True,
                reason=f"{magic} container, not a tiled LUT source",
            ))
        return out
    # Unrecognised magic: this is how the obfuscated subset shows up.
    if name_hint or path.suffix.lower() in IMAGE_SUFFIXES:
        out.append(_make_candidate(
            path, root, type="obfuscated_container", size_bytes=size,
            magic=magic, confidence=0.1, method="magic",
            excluded=True,
            reason=("unrecognised container for a LUT-named asset "
                    "(likely obfuscated/encrypted)"),
        ))
    return out


def scan_binary_file(path: Path, root: Path, name_hint: bool) -> list[dict]:
    size = path.stat().st_size
    if size < 4096:
        return []
    grids = guess_binary_grid(size) if name_hint else []
    if grids:
        return [
            _make_candidate(
                path, root, type="binary_grid", size_bytes=size, magic=sniff_magic(path),
                lut_size=g["lut_size"], layout=g["layout"], confidence=g["confidence"],
                method="binary_size_match", dtype=g.get("dtype"),
            )
            for g in grids
        ]
    if name_hint:
        ent = file_entropy(path)
        return [_make_candidate(
            path, root, type="opaque_binary", size_bytes=size, magic=sniff_magic(path),
            confidence=0.0, method="entropy", entropy=round(ent, 3),
            excluded=True,
            reason=f"high-entropy payload (H={ent:.2f}/8); no LUT signature",
        )]
    return []


def scan_source_file(path: Path, root: Path) -> list[dict]:
    if path.name == "R.java":
        return []  # generated resource-id tables are never colour LUTs
    try:
        if path.stat().st_size > MAX_SOURCE_FILE_BYTES:
            return []
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    if not any(k in text.lower() for k in SOURCE_KEYWORDS):
        return []
    out: list[dict] = []
    for match in ARRAY_RE.finditer(text):
        body = match.group("body")
        numbers = NUMBER_RE.findall(body)
        if len(numbers) < 256:
            continue
        window = text[max(0, match.start() - 180): match.start()]
        near = sorted({k for k in SOURCE_KEYWORDS if k in window.lower()})
        length = len(numbers)
        suspicious = length in SUSPICIOUS_LENGTHS
        if not suspicious and not near:
            continue
        conf = 0.6 if (suspicious and near) else 0.45 if suspicious else 0.3
        rng = _numeric_range(numbers)
        out.append(_make_candidate(
            path, root, type="source_table", size_bytes=len(body),
            lut_size=None, layout=f"{length} numeric literals",
            confidence=conf, method="source_array_scan",
            array_length=length, near_keywords=near,
            numeric_range=rng,
            line=text.count("\n", 0, match.start()) + 1,
        ))
        if len(out) >= MAX_SOURCE_CANDIDATES_PER_FILE:
            break
    return out


def _numeric_range(numbers: list[str]):
    lo = None
    hi = None
    for tok in numbers[:20000]:
        try:
            val = float(tok.rstrip("fFdDlL"))
        except ValueError:
            continue
        lo = val if lo is None else min(lo, val)
        hi = val if hi is None else max(hi, val)
    if lo is None:
        return None
    return [round(lo, 6), round(hi, 6)]


def _name_has_hint(path: Path) -> bool:
    blob = (path.name + "/" + path.parent.name).lower()
    return any(h in blob for h in LUT_NAME_HINTS)


def scan_tree(root: Path, *, include_source: bool = True) -> list[dict]:
    candidates: list[dict] = []
    source_files = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        try:
            if suffix == ".cube":
                candidates.append(scan_cube_file(path, root))
            elif suffix in IMAGE_SUFFIXES:
                candidates.extend(
                    scan_image_file(path, root, _name_has_hint(path)))
            elif suffix in (".dat", ".bin", ".raw", ".lut", ".icc"):
                candidates.extend(
                    scan_binary_file(path, root, _name_has_hint(path)))
            elif suffix in SOURCE_SUFFIXES and include_source and suffix in (".java", ".kt"):
                if source_files < MAX_SOURCE_FILES:
                    source_files += 1
                    candidates.extend(scan_source_file(path, root))
        except Exception as exc:  # never let one bad file kill the scan
            candidates.append(_make_candidate(
                path, root, type="error", confidence=0.0,
                method="scan", excluded=True, reason=f"scan error: {exc}",
            ))
    return candidates


# --------------------------------------------------------------------------- #
# Extraction
# --------------------------------------------------------------------------- #

def _default_axes_for(tile_axis: str, x_axis: str, y_axis: str) -> bool:
    return {tile_axis, x_axis, y_axis} == {"r", "g", "b"}


def extract_candidates(candidates: list[dict], root: Path, extract_dir: Path, *,
                       lut_size_override: int | None, min_confidence: float,
                       tile_axis: str, x_axis: str, y_axis: str,
                       quiet: bool) -> list[dict]:
    emitted: list[dict] = []
    if np is None:
        print("warning: numpy unavailable; skipping extraction", file=sys.stderr)
        return emitted
    for cand in candidates:
        if cand.get("excluded") or cand["confidence"] < min_confidence:
            continue
        if cand["type"] != "png_lut":
            continue
        src = root / cand["path"]
        n = lut_size_override or cand.get("lut_size")
        if not n:
            continue
        cols = cand.get("layout", "")
        tile_cols = math.ceil(math.sqrt(n))
        m = re.match(r"(\d+)x", cols or "")
        if m:
            tile_cols = int(m.group(1))
        try:
            img = load_image_rgb(src)
            if img is None:
                continue
            lut = assemble_tiles_tiled(img, n, tile_cols,
                                       tile_axis=tile_axis,
                                       x_axis=x_axis, y_axis=y_axis)
        except Exception as exc:
            print(f"warning: could not decode {src}: {exc}", file=sys.stderr)
            continue
        stem = Path(cand["path"]).with_suffix("")
        cube_path = extract_dir / stem.with_suffix(".cube")
        write_cube(lut, cube_path, title=f"LUT {n}^3 from {cand['path']}")
        sidecar = cube_path.with_suffix(".json")
        meta = {
            "source_file": cand["path"],
            "source_sha256_1mb": sha256_of(src),
            "source_size_bytes": cand["size_bytes"],
            "method": "png_tiled_lut",
            "lut_size": n,
            "tile_cols": tile_cols,
            "tile_rows": math.ceil(n / tile_cols),
            "axes": {"tile": tile_axis, "x": x_axis, "y": y_axis},
            "confidence": cand["confidence"],
            "emitted_cube": _relpath(cube_path, extract_dir),
        }
        sidecar.write_text(json.dumps(meta, indent=2), encoding="utf-8")
        emitted.append({"cube": _relpath(cube_path, extract_dir),
                        "sidecar": _relpath(sidecar, extract_dir), **meta})
        if not quiet:
            print(f"extracted {cube_path}  ({n}^3)")
    return emitted


# --------------------------------------------------------------------------- #
# Reporting + CLI
# --------------------------------------------------------------------------- #

def build_report(root: Path, candidates: list[dict], mode: str,
                 emitted: list[dict]) -> dict:
    kept = [c for c in candidates if not c.get("excluded")]
    excluded = [c for c in candidates if c.get("excluded")]
    by_type = Counter(c["type"] for c in candidates)
    return {
        "tool": "parse_luts",
        "version": 1,
        "scan_root": str(root),
        "mode": mode,
        "generated_epoch": int(time.time()),
        "candidates": candidates,
        "excluded": excluded,
        "emitted": emitted,
        "summary": {
            "candidates": len(kept),
            "excluded": len(excluded),
            "by_type": dict(by_type.most_common()),
            "extractable_png_luts": sum(
                1 for c in kept if c["type"] == "png_lut"),
        },
    }


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Scan a dump/source tree for 3D-LUT candidates.")
    p.add_argument("--scan", required=True, type=Path, help="Directory to scan.")
    p.add_argument("--inventory", action="store_true",
                   help="Report only; do not write .cube files.")
    p.add_argument("--out", type=Path, default=None,
                   help="Write the JSON report to this file (default: stdout).")
    p.add_argument("--extract-dir", type=Path, default=None,
                   help="Directory for emitted .cube + sidecars "
                        "(default: ./luts_out).")
    p.add_argument("--lut-size", type=int, default=None,
                   help="Reinterpret the tile grid as N^3 (does NOT resample; "
                        "use for alternate tile layouts).")
    p.add_argument("--min-confidence", type=float, default=0.5,
                   help="Minimum confidence to extract (default: 0.5).")
    p.add_argument("--tile-axis", choices=("r", "g", "b"), default="b")
    p.add_argument("--x-axis", choices=("r", "g", "b"), default="r")
    p.add_argument("--y-axis", choices=("r", "g", "b"), default="g")
    p.add_argument("--no-source", action="store_true",
                   help="Skip decompiled-source numeric-table scanning.")
    p.add_argument("--quiet", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root: Path = args.scan
    if not root.is_dir():
        print(f"error: scan dir not found: {root}", file=sys.stderr)
        return 2
    if not _default_axes_for(args.tile_axis, args.x_axis, args.y_axis):
        print("error: --tile-axis/--x-axis/--y-axis must be a permutation of r,g,b",
              file=sys.stderr)
        return 2

    candidates = scan_tree(root, include_source=not args.no_source)
    emitted: list[dict] = []
    mode = "inventory"
    if not args.inventory:
        mode = "extract"
        extract_dir = args.extract_dir or (Path.cwd() / "luts_out")
        emitted = extract_candidates(
            candidates, root, extract_dir,
            lut_size_override=args.lut_size,
            min_confidence=args.min_confidence,
            tile_axis=args.tile_axis, x_axis=args.x_axis, y_axis=args.y_axis,
            quiet=args.quiet,
        )
    report = build_report(root, candidates, mode, emitted)
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
