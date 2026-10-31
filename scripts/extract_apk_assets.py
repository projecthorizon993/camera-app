#!/usr/bin/env python3
"""extract_apk_assets.py -- unpack an APK / split-APK set / XAPK and inventory it.

Clean-room note
---------------
This tool only inspects *archive structure*. It never writes into the camera-app
repo. Point ``--out`` at a scratch directory (the system temp dir, or a CI
workspace path that is git-ignored) -- see ``docs/extraction-notes.md``. Nothing
produced by this script is committed; only *derived generic parameters* may be
committed, and only by the parse_* tooling.

Supported inputs
----------------
* a single ``.apk`` (base or ``config.*`` split)
* a directory containing a split set (``com.vendor.app.apk`` + ``config.*.apk``)
* an ``.xapk`` / ``.apks`` / ``.zip`` bundle whose members are APK splits

CLI
---
    extract_apk_assets.py --apk PATH --out DIR [--json FILE] [--quiet]

Prints an inventory: file count by extension, top-level directories, total size.
Pure standard library (``zipfile``); runs on Python 3.12.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

ARCHIVE_SUFFIXES = (".apk", ".xapk", ".apks", ".zip")
SPLIT_PREFIX = "config."
MAX_MEMBER_BYTES = 4 * 1024 * 1024 * 1024  # sanity guard, 4 GiB


@dataclass
class Inventory:
    archives: list[str] = field(default_factory=list)
    files: int = 0
    total_bytes: int = 0
    by_ext: Counter = field(default_factory=Counter)
    top_dirs: Counter = field(default_factory=Counter)
    skipped: list[str] = field(default_factory=list)

    def record(self, member_name: str, size: int) -> None:
        norm = member_name.replace("\\", "/").lstrip("/")
        # Extension bucket: lowercase suffix, "<none>" when absent.
        name = norm.rsplit("/", 1)[-1]
        ext = Path(name).suffix.lower().lstrip(".") or "<none>"
        self.by_ext[ext] += 1
        top = norm.split("/", 1)[0] if "/" in norm else "<root>"
        self.top_dirs[top] += 1
        self.files += 1
        self.total_bytes += int(size)

    def to_dict(self) -> dict:
        return {
            "archives": list(self.archives),
            "files": self.files,
            "total_bytes": self.total_bytes,
            "by_ext": dict(self.by_ext.most_common()),
            "top_dirs": dict(self.top_dirs.most_common()),
            "skipped": list(self.skipped),
        }


def _safe_member_path(dest_root: Path, member_name: str) -> Path | None:
    """Resolve a zip member to a path inside ``dest_root`` or return None (zip-slip)."""
    norm = member_name.replace("\\", "/")
    if not norm or norm.endswith("/"):
        return None
    if norm.startswith("/") or norm.startswith("../") or "/../" in norm or norm == "..":
        return None
    root = dest_root.resolve()
    target = (root / norm).resolve()
    try:
        target.relative_to(root)
    except ValueError:
        return None
    return target


def _is_split_name(name: str) -> bool:
    return Path(name).name.lower().startswith(SPLIT_PREFIX)


def _order_split_names(names: list[str]) -> list[str]:
    """Base archives first, then ``config.*`` splits, each group sorted."""
    bases = sorted(n for n in names if not _is_split_name(n))
    splits = sorted(n for n in names if _is_split_name(n))
    return bases + splits


def extract_archive(
    archive: Path,
    dest: Path,
    inv: Inventory,
    *,
    skip_members: tuple[str, ...] = (),
    skip_apks: bool = False,
) -> None:
    """Extract a single zip-format archive into ``dest`` and record inventory."""
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if skip_members and name.endswith(skip_members):
                continue
            if info.file_size > MAX_MEMBER_BYTES:
                inv.skipped.append(f"{name} (too large: {info.file_size})")
                continue
            target = _safe_member_path(dest, name)
            if target is None:
                inv.skipped.append(f"{name} (unsafe path)")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            inv.record(name, info.file_size)


def _inner_apk_names(archive: Path) -> list[str]:
    with zipfile.ZipFile(archive) as zf:
        names = [i.filename for i in zf.infolist() if not i.is_dir()]
    return [n for n in names if Path(n).suffix.lower() == ".apk"]


def handle_archive(archive: Path, out_dir: Path, inv: Inventory, *, quiet: bool) -> None:
    """Dispatch one input archive: plain APK vs. bundle (XAPK/APKS)."""
    inv.archives.append(archive.name)
    suffix = archive.suffix.lower()
    if suffix == ".apk":
        extract_archive(archive, out_dir, inv)
        return

    inner = _inner_apk_names(archive)
    if not inner:
        # A .zip/.apks that is not a bundle: just unpack it.
        extract_archive(archive, out_dir, inv)
        return

    if not quiet:
        kind = "base" if not _is_split_name(archive.name) else "split"
        print(f"[bundle:{kind}] {archive.name} -> {len(inner)} inner APK(s)")
    with tempfile.TemporaryDirectory(prefix="apk_split_") as tmp:
        tmp_dir = Path(tmp)
        # Pull the inner APKs out of the bundle into scratch, then unpack each.
        extract_archive(archive, tmp_dir, Inventory(), skip_apks=False)
        for inner_name in _order_split_names(inner):
            inner_path = tmp_dir / inner_name.replace("\\", "/")
            if not inner_path.is_file():
                inv.skipped.append(f"{inner_name} (missing after bundle unpack)")
                continue
            if not quiet:
                tag = "split" if _is_split_name(inner_name) else "base"
                print(f"  [{tag}] {inner_name}")
            extract_archive(inner_path, out_dir, inv)


def process_target(target: Path, out_dir: Path, *, quiet: bool = False) -> Inventory:
    inv = Inventory()
    if target.is_dir():
        apks = sorted(
            p for p in target.iterdir()
            if p.is_file() and p.suffix.lower() in ARCHIVE_SUFFIXES
        )
        if not apks:
            raise FileNotFoundError(f"no archives found in directory: {target}")
        for apk in apks:
            handle_archive(apk, out_dir, inv, quiet=quiet)
    else:
        handle_archive(target, out_dir, inv, quiet=quiet)
    return inv


def _format_human_report(target: Path, out_dir: Path, inv: Inventory, top_n: int = 12) -> str:
    lines: list[str] = []
    lines.append(f"input:      {target}")
    lines.append(f"output:     {out_dir}")
    lines.append(f"archives:   {', '.join(inv.archives) if inv.archives else '<none>'}")
    lines.append(f"files:      {inv.files}")
    lines.append(f"total size: {inv.total_bytes} bytes ({inv.total_bytes / 1048576:.1f} MiB)")
    lines.append("by extension:")
    for ext, count in inv.by_ext.most_common(top_n):
        lines.append(f"  {ext:<10} {count}")
    lines.append("top-level dirs:")
    for topd, count in inv.top_dirs.most_common(top_n):
        lines.append(f"  {topd:<28} {count}")
    if inv.skipped:
        lines.append(f"skipped:    {len(inv.skipped)}")
        for s in inv.skipped[:top_n]:
            lines.append(f"  - {s}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Unpack an APK / split-APK set / XAPK and print an inventory.",
    )
    p.add_argument("--apk", required=True, type=Path,
                   help="APK file, XAPK/APKS bundle, or a directory of split APKs.")
    p.add_argument("--out", required=True, type=Path,
                   help="Scratch directory to unpack into (do not use the repo).")
    p.add_argument("--json", type=Path, default=None,
                   help="Optional path to write the inventory as JSON.")
    p.add_argument("--quiet", action="store_true", help="Suppress per-archive progress.")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    target: Path = args.apk
    if not target.exists():
        print(f"error: input not found: {target}", file=sys.stderr)
        return 2
    out_dir: Path = args.out
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        print(f"error: cannot create output dir {out_dir}: {exc}", file=sys.stderr)
        return 2

    try:
        inv = process_target(target, out_dir, quiet=args.quiet)
    except (zipfile.BadZipFile, FileNotFoundError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(_format_human_report(target, out_dir, inv))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(inv.to_dict(), indent=2), encoding="utf-8")
        print(f"wrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
