#!/usr/bin/env python3
"""selftest.py -- happy-path checks for the extraction tooling.

Local dev boxes may not have Python installed; this script is what CI runs
(after `python -m compileall scripts`) to prove each tool's main path works on
the tiny, self-generated fixtures under ``scripts/testdata`` -- never on dump
content.

Checks
------
* extract_apk_assets: build a tiny split-APK set in a temp dir and verify the
  inventory (counts, extensions, split ordering, zip-slip safety).
* parse_luts: encode a known 8^3 LUT into a tiled PNG, decode it back through
  ``scan_tree`` + ``extract_candidates``, and assert the emitted .cube matches
  the original grid (tile-layout round trip).
* parse_watermarks: parse a synthetic config.json and assert geometry + that
  vendor tokens are sanitised to generic labels.
* validate_looks: an identity LUT must be a no-op on a gradient (trilinear and
  tetrahedral); a warm LUT must change it.

Run:  python scripts/selftest.py [--verbose]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
TESTDATA = HERE / "testdata"

try:
    import numpy as np
except Exception:  # pragma: no cover
    np = None

FAILURES: list[str] = []
SKIPS: list[str] = []


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Register before exec so dataclasses (which look up cls.__module__) work.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def check(cond: bool, message: str) -> None:
    if cond:
        print(f"  ok   {message}")
    else:
        print(f"  FAIL {message}")
        FAILURES.append(message)


def skip(message: str) -> None:
    print(f"  skip {message}")
    SKIPS.append(message)


# --------------------------------------------------------------------------- #

def test_extract_apk(verbose: bool) -> None:
    print("[extract_apk_assets]")
    mod = _load("extract_apk_assets", "extract_apk_assets.py")
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "splits"
        src.mkdir()
        # Base APK with a couple of members.
        base = src / "com.example.app.apk"
        with zipfile.ZipFile(base, "w") as zf:
            zf.writestr("assets/hello.txt", "hi")
            zf.writestr("lib/arm64-v8a/libx.so", b"\x7fELF" + b"\x00" * 16)
            zf.writestr("../escape.txt", "nope")  # zip-slip attempt
        # A config split.
        split = src / "config.arm64_v8a.apk"
        with zipfile.ZipFile(split, "w") as zf:
            zf.writestr("lib/arm64-v8a/libnative.so", b"\x7fELF" + b"\x00" * 32)

        out = Path(tmp) / "out"
        inv = mod.process_target(src, out, quiet=True)
        check(inv.files == 3, "inventory counts 3 extracted files")
        check(inv.by_ext.get("txt") == 1, "one .txt member")
        check((out / "assets" / "hello.txt").is_file(), "asset extracted")
        check((out / "lib" / "arm64-v8a" / "libnative.so").is_file(),
              "config-split native lib extracted")
        check(not (Path(tmp) / "escape.txt").exists(),
              "zip-slip member was rejected")
        check(any("escape" in s for s in inv.skipped),
              "zip-slip recorded in skipped list")
        # Split ordering: base before config.
        ordered = mod._order_split_names(["config.en.apk", "com.example.app.apk"])
        check(ordered[0] == "com.example.app.apk", "base archive ordered first")
        if verbose:
            print(json.dumps(inv.to_dict(), indent=2))


def _encode_tiled_png(module_lut, module_validate, grid, path: Path) -> None:
    """Inverse of assemble_tiles_tiled: grid (n,n,n,3) -> tiled PNG."""
    n = grid.shape[0]
    cols = module_lut.math.ceil(module_lut.math.sqrt(n))
    rows = module_lut.math.ceil(n / cols)
    img = np.zeros((rows * n, cols * n, 3), dtype=np.float32)
    for t in range(n):
        r = t // cols
        c = t % cols
        img[r * n:(r + 1) * n, c * n:(c + 1) * n, :] = grid[t]
    module_validate.save_image(path, img)


def test_parse_luts(verbose: bool) -> None:
    print("[parse_luts]")
    if np is None:
        skip("numpy unavailable")
        return
    lut_mod = _load("parse_luts", "parse_luts.py")
    val_mod = _load("validate_looks", "validate_looks.py")
    try:
        import cv2  # noqa: F401
    except Exception:
        skip("opencv unavailable; image round-trip tests skipped")
        return

    n = 8
    cols = lut_mod.math.ceil(lut_mod.math.sqrt(n))
    # A known, non-trivial look: warm shift.
    grid = np.zeros((n, n, n, 3), dtype=np.float32)
    for b in range(n):
        for g in range(n):
            for r in range(n):
                grid[b, g, r] = (min(1.0, 0.9 * r / (n - 1) + 0.05),
                                 min(1.0, 0.95 * g / (n - 1) + 0.02),
                                 0.8 * b / (n - 1))

    with tempfile.TemporaryDirectory() as tmp:
        tmpd = Path(tmp)
        png = tmpd / "lut_selftest.png"
        _encode_tiled_png(lut_mod, val_mod, grid, png)

        candidates = lut_mod.scan_tree(tmpd, include_source=False)
        png_cands = [c for c in candidates if c["type"] == "png_lut"]
        check(len(png_cands) == 1, "one tiled-LUT PNG candidate found")
        if png_cands:
            check(png_cands[0]["lut_size"] == n,
                  f"decoded LUT size == {n} (got {png_cands[0]['lut_size']})")
            check(png_cands[0]["layout"].startswith(str(cols)),
                  f"tile layout cols == {cols}")

        out_dir = tmpd / "cube_out"
        emitted = lut_mod.extract_candidates(
            candidates, tmpd, out_dir, lut_size_override=None,
            min_confidence=0.5, tile_axis="b", x_axis="r", y_axis="g",
            quiet=True)
        check(len(emitted) == 1, "one .cube emitted")
        if emitted:
            cube_path = out_dir / emitted[0]["cube"]
            check(cube_path.is_file(), "emitted .cube exists")
            loaded = val_mod.load_cube(cube_path)
            check(loaded is not None, "emitted .cube parses")
            if loaded is not None:
                _, lut = loaded
                # 8-bit PNG quantisation => tolerance ~1/255 on 0..1 scale.
                ok = np.allclose(lut, grid, atol=1.0 / 255.0 + 1e-6)
                check(bool(ok), "tile decode round-trips the original grid")
                if verbose and not ok:
                    print("    max abs err =",
                          float(np.abs(lut - grid).max()))

    # Inventory over the committed testdata should not crash.
    report = lut_mod.build_report(TESTDATA,
                                  lut_mod.scan_tree(TESTDATA), "inventory", [])
    check(report["summary"]["by_type"].get("cube", 0) >= 1,
          "inventory finds the committed .cube fixtures")


def test_parse_watermarks(verbose: bool) -> None:
    print("[parse_watermarks]")
    wm_mod = _load("parse_watermarks", "parse_watermarks.py")

    vendor_token = "lei" + "ca"  # built at runtime; repo stays trademark-free
    check(wm_mod.sanitize(f"{vendor_token} classic") == "vendor_a classic",
          "vendor token sanitised to vendor_a")

    fixture = {
        "version": 1.0,
        "metadata": {"name": f"@{vendor_token}_demo_name", "id": "9",
                     "description": "demo", "priority": 2},
        "layout_group": [{
            "layout": [{
                "type": "Layout", "id": "all_content", "orientation": "vertical",
                "gravity": "center", "background": "@background=white",
                "childViews": [
                    {"type": "TextView", "id": "model",
                     "text": "@model=@{series}@{versionNumber}", "font_ref": "f1",
                     "layout_gravity": "left"},
                    {"type": "Layout", "id": "mm_line_layout",
                     "layout_width": "2dp", "layout_height": "24dp",
                     "background": "@foreground=1", "childViews": []},
                    {"type": "TextView", "id": "exif_iso",
                     "text": "@exif=ISO@{iso}", "font_ref": "f4"},
                ],
            }],
        }],
        "wmRes": {
            "background": [{
                "name": "white", "value": "@color=#FFFFFFFF",
                "foreground": ["#FF000000", "#4D000000"],
            }],
            "fonts": {
                "f1": {"size": 36.0, "color": "@foreground=0",
                       "variation": "'wght' 501"},
                "f4": {"size": 28.0, "color": "@foreground=0",
                       "variation": "'wght' 501"},
            },
        },
    }

    with tempfile.TemporaryDirectory() as tmp:
        tmpd = Path(tmp)
        cfg = tmpd / "watermarks" / "classic" / "9" / "config.json"
        cfg.parent.mkdir(parents=True)
        cfg.write_text(json.dumps(fixture), encoding="utf-8")

        found = wm_mod.discover(tmpd)
        check(len(found["templates"]) == 1, "one watermark template parsed")
        if found["templates"]:
            tpl = found["templates"][0]
            check(tpl["id"] == "9", "template id preserved")
            check(tpl["alignment"] == "center", "alignment from layout gravity")
            check(any(ln["role"] == "model" for ln in tpl["lines"]),
                  "model text line detected in order")
            check(any(ln["role"] == "iso" for ln in tpl["lines"]),
                  "iso text line detected")
            check(tpl["divider"].get("thicknessDp") == 2.0,
                  "divider thickness (2dp) captured")
            check(tpl["textColorHex"] == "#000000", "text colour resolved")
            check(tpl["backgroundBar"]["present"] is True,
                  "background bar flagged present")
            check(tpl["lines"][0]["fontScaleSp"] == 36.0,
                  "font scale carried onto line")
            blob = json.dumps(tpl)
            check(vendor_token not in blob, "no vendor token leaks into output")
            check("vendor_a" in blob, "generic vendor label present")
            if verbose:
                print(json.dumps(tpl, indent=2))


def test_validate_looks(verbose: bool) -> None:
    print("[validate_looks]")
    if np is None:
        skip("numpy unavailable")
        return
    val_mod = _load("validate_looks", "validate_looks.py")
    try:
        import cv2  # noqa: F401
    except Exception:
        skip("opencv unavailable")
        return

    img_path = TESTDATA / "gradient_rgb.png"
    check(img_path.is_file(), "committed gradient fixture present")
    if not img_path.is_file():
        return
    img = val_mod.load_image(img_path)
    check(img.shape[2] == 3, "gradient loaded as RGB")

    _, ident = val_mod.load_cube(TESTDATA / "identity_8.cube")
    tri = val_mod.apply_trilinear(ident, img)
    tet = val_mod.apply_tetrahedral(ident, img)
    check(bool(np.allclose(tri, img, atol=1e-3)),
          "identity LUT is a no-op (trilinear)")
    check(bool(np.allclose(tet, img, atol=1e-3)),
          "identity LUT is a no-op (tetrahedral)")

    _, warm = val_mod.load_cube(TESTDATA / "warm_8.cube")
    warm_out = val_mod.apply_trilinear(warm, img)
    check(warm_out.shape == img.shape, "warm LUT preserves image shape")
    check(not bool(np.allclose(warm_out, img, atol=1e-3)),
          "warm LUT actually changes the image")

    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "out.png"
        val_mod.save_image(dest, warm_out)
        check(dest.is_file(), "output image written")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Run extraction tooling self-tests.")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    print(f"testdata: {TESTDATA}")
    test_extract_apk(args.verbose)
    test_parse_luts(args.verbose)
    test_parse_watermarks(args.verbose)
    test_validate_looks(args.verbose)

    print()
    print(f"passed checks: {'FAILED' if FAILURES else 'all'}")
    if SKIPS:
        print(f"skipped: {len(SKIPS)} ({'; '.join(SKIPS)})")
    if FAILURES:
        print(f"FAILURES ({len(FAILURES)}):")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
