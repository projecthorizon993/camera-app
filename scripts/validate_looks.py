#!/usr/bin/env python3
"""validate_looks.py -- apply a .cube 3D LUT to a test image and save the result.

Used to verify that a LUT extracted by :mod:`parse_luts` behaves correctly
(identity LUTs are a no-op; generated gradients make the effect visible).

CLI
---
    validate_looks.py --lut FILE --image IMG [--out OUT]
                      [--mode trilinear|tetrahedral]
    validate_looks.py --make-gradients DIR      # write tiny test inputs

Requires numpy (+ opencv-python-headless for image I/O). Image arrays are
handled as RGB internally; OpenCV's BGR convention is respected on load/save.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

try:
    import cv2  # type: ignore
except Exception:  # pragma: no cover - cv2 is a declared dependency
    cv2 = None


# --------------------------------------------------------------------------- #
# .cube I/O (self-contained so this module has no intra-package import)
# --------------------------------------------------------------------------- #

def load_cube(path: Path):
    """Return (size, lut) with lut shaped (N, N, N, 3) float32 in [0, 1].

    The array is in .cube order, i.e. indexed ``lut[blue, green, red]``
    (red index varies fastest in the file).
    """
    size = None
    domain_min = np.array([0.0, 0.0, 0.0], dtype=np.float32)
    domain_max = np.array([1.0, 1.0, 1.0], dtype=np.float32)
    values: list[tuple[float, float, float]] = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            upper = line.upper()
            if upper.startswith("LUT_3D_SIZE"):
                size = int(line.split()[1])
            elif upper.startswith("LUT_1D_SIZE"):
                raise ValueError("1D LUTs are not supported")
            elif upper.startswith("DOMAIN_MIN"):
                domain_min = np.array([float(x) for x in line.split()[1:4]],
                                      dtype=np.float32)
            elif upper.startswith("DOMAIN_MAX"):
                domain_max = np.array([float(x) for x in line.split()[1:4]],
                                      dtype=np.float32)
            elif upper.startswith("TITLE"):
                continue
            else:
                try:
                    values.append((float(line.split()[0]),
                                   float(line.split()[1]),
                                   float(line.split()[2])))
                except (ValueError, IndexError):
                    continue
    if not size:
        raise ValueError(f"no LUT_3D_SIZE in {path}")
    expected = size ** 3
    if len(values) < expected:
        raise ValueError(f"expected {expected} entries, found {len(values)}")
    lut = np.asarray(values[:expected], dtype=np.float32)
    lut = (lut - domain_min) / np.maximum(domain_max - domain_min, 1e-9)
    return size, np.clip(lut.reshape(size, size, size, 3), 0.0, 1.0)


# --------------------------------------------------------------------------- #
# Interpolation
# --------------------------------------------------------------------------- #

def _corners(lut, coords, n):
    idx0 = np.floor(coords).astype(np.int32)
    idx0 = np.clip(idx0, 0, n - 1)
    idx1 = np.clip(idx0 + 1, 0, n - 1)
    frac = np.clip(coords - idx0, 0.0, 1.0)

    # ``lut`` is stored in .cube order, i.e. indexed [blue, green, red].
    r0, g0, b0 = idx0[..., 0], idx0[..., 1], idx0[..., 2]
    r1, g1, b1 = idx1[..., 0], idx1[..., 1], idx1[..., 2]
    corners = {
        "000": lut[b0, g0, r0],
        "100": lut[b0, g0, r1],
        "010": lut[b0, g1, r0],
        "001": lut[b1, g0, r0],
        "110": lut[b0, g1, r1],
        "101": lut[b1, g0, r1],
        "011": lut[b1, g1, r0],
        "111": lut[b1, g1, r1],
    }
    return corners, frac


def apply_trilinear(lut, img):
    """img: (H, W, 3) float in [0, 1]; lut: (N, N, N, 3). Returns (H, W, 3)."""
    n = lut.shape[0]
    coords = np.clip(img, 0.0, 1.0) * (n - 1)
    c, f = _corners(lut, coords, n)
    r, g, b = f[..., 0:1], f[..., 1:2], f[..., 2:3]
    c00 = c["000"] * (1 - r) + c["100"] * r
    c01 = c["001"] * (1 - r) + c["101"] * r
    c10 = c["010"] * (1 - r) + c["110"] * r
    c11 = c["011"] * (1 - r) + c["111"] * r
    c0 = c00 * (1 - g) + c10 * g
    c1 = c01 * (1 - g) + c11 * g
    return c0 * (1 - b) + c1 * b


def apply_tetrahedral(lut, img):
    """Vectorised tetrahedral interpolation (same I/O contract as trilinear)."""
    n = lut.shape[0]
    coords = np.clip(img, 0.0, 1.0) * (n - 1)
    c, f = _corners(lut, coords, n)
    r, g, b = f[..., 0:1], f[..., 1:2], f[..., 2:3]

    choices = [
        # r >= g >= b
        (1 - r) * c["000"] + (r - g) * c["100"] + (g - b) * c["110"] + b * c["111"],
        # r >= b > g
        (1 - r) * c["000"] + (r - b) * c["100"] + (b - g) * c["101"] + g * c["111"],
        # b > r >= g
        (1 - b) * c["000"] + (b - r) * c["001"] + (r - g) * c["101"] + g * c["111"],
        # g > r ; b >= g > r
        (1 - b) * c["000"] + (b - g) * c["001"] + (g - r) * c["011"] + r * c["111"],
        # g > r ; g > b ; b >= r -> g >= b >= r
        (1 - g) * c["000"] + (g - b) * c["010"] + (b - r) * c["011"] + r * c["111"],
        # g > r > b
        (1 - g) * c["000"] + (g - r) * c["010"] + (r - b) * c["110"] + b * c["111"],
    ]
    # Six mutually exclusive, exhaustive ordering regions of the unit cube.
    conditions = [
        (r >= g) & (g >= b),        # r >= g >= b
        (r >= g) & (g < b) & (r >= b),  # r >= b > g
        (r >= g) & (g < b) & (r < b),   # b > r >= g
        (r < g) & (b >= g),         # b >= g > r
        (r < g) & (b < g) & (b >= r),   # g > b >= r
        (r < g) & (b < g) & (b < r),    # g > r > b
    ]
    return np.select(conditions, choices, default=choices[5])


# --------------------------------------------------------------------------- #
# Image I/O
# --------------------------------------------------------------------------- #

def load_image(path: Path):
    if cv2 is None:
        raise RuntimeError("opencv-python-headless is required for image I/O")
    bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if bgr is None:
        raise ValueError(f"could not read image: {path}")
    return bgr[:, :, ::-1].astype(np.float32) / 255.0  # BGR -> RGB, [0, 1]


def save_image(path: Path, rgb) -> None:
    if cv2 is None:
        raise RuntimeError("opencv-python-headless is required for image I/O")
    arr = np.clip(rgb, 0.0, 1.0)
    bgr = (arr[:, :, ::-1] * 255.0 + 0.5).astype(np.uint8)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(path), bgr):
        raise OSError(f"could not write image: {path}")


# --------------------------------------------------------------------------- #
# Test gradients
# --------------------------------------------------------------------------- #

def _hsv_to_rgb(h, s, v):
    """h in [0,1), s, v arrays in [0,1] -> RGB array."""
    i = np.floor(h * 6.0)
    f = h * 6.0 - i
    p = v * (1.0 - s)
    q = v * (1.0 - f * s)
    t = v * (1.0 - (1.0 - f) * s)
    i = i.astype(np.int32) % 6
    conds = [i == k for k in range(6)]
    r = np.select(conds, [v, q, p, p, t, v])
    g = np.select(conds, [t, v, v, q, p, p])
    b = np.select(conds, [p, p, t, v, v, q])
    return np.stack([r, g, b], axis=-1)


def make_gradients(out_dir: Path, *, quiet: bool = False) -> list[Path]:
    """Write three tiny gradient PNGs (no external assets). Returns paths."""
    out_dir.mkdir(parents=True, exist_ok=True)
    made: list[Path] = []

    # 1. RGB axes gradient: x -> R, y -> G, B = 0.5.
    w, h = 64, 16
    rr = np.linspace(0, 1, w, dtype=np.float32)[None, :].repeat(h, axis=0)
    gg = np.linspace(0, 1, h, dtype=np.float32)[:, None].repeat(w, axis=1)
    bb = np.full((h, w), 0.5, dtype=np.float32)
    p1 = out_dir / "gradient_rgb.png"
    save_image(p1, np.stack([rr, gg, bb], axis=-1))
    made.append(p1)

    # 2. Grey ramp (black -> white).
    ramp = np.linspace(0, 1, 256, dtype=np.float32)[None, :].repeat(4, axis=0)
    p2 = out_dir / "gradient_ramp.png"
    save_image(p2, np.stack([ramp, ramp, ramp], axis=-1))
    made.append(p2)

    # 3. Hue sweep at full saturation, value ramped vertically.
    hue = np.linspace(0, 1, 256, endpoint=False, dtype=np.float32)[None, :]
    val = np.linspace(0.25, 1.0, 16, dtype=np.float32)[:, None]
    hue2 = np.repeat(hue, 16, axis=0)
    val2 = np.repeat(val, 256, axis=1)
    sat2 = np.ones_like(hue2)
    p3 = out_dir / "gradient_hue.png"
    save_image(p3, _hsv_to_rgb(hue2, sat2, val2))
    made.append(p3)

    if not quiet:
        for p in made:
            print(f"wrote {p}")
    return made


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Apply a .cube LUT to an image.")
    p.add_argument("--lut", type=Path, help="Input .cube file.")
    p.add_argument("--image", type=Path, help="Input image.")
    p.add_argument("--out", type=Path, default=None,
                   help="Output image (default: <image>.lut.png).")
    p.add_argument("--mode", choices=("trilinear", "tetrahedral"),
                   default="trilinear")
    p.add_argument("--make-gradients", type=Path, default=None,
                   help="Write test gradient PNGs to DIR and exit.")
    p.add_argument("--quiet", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.make_gradients:
        make_gradients(args.make_gradients, quiet=args.quiet)
        return 0

    if not args.lut or not args.image:
        print("error: --lut and --image are required (or use --make-gradients)",
              file=sys.stderr)
        return 2
    try:
        _, lut = load_cube(args.lut)
        img = load_image(args.image)
        out = (apply_tetrahedral if args.mode == "tetrahedral"
               else apply_trilinear)(lut, img)
        dest = args.out or args.image.with_suffix(
            args.image.suffix + f".{args.mode}.png")
        save_image(dest, out)
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if not args.quiet:
        print(f"{args.mode}: {args.image} + {args.lut} -> {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
