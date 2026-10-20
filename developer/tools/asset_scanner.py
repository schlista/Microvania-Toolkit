#!/usr/bin/env python3
"""
Asset/Reference Scanner

Validates common asset references so artists/devs catch broken paths early:
- Tilemaps -> tilesources
- Sprites   -> atlases
- Atlases   -> source images

Usage:
  python developer/tools/asset_scanner.py
  python developer/tools/asset_scanner.py --root /path/to/project
"""
import argparse
import re
import sys
from pathlib import Path


def load_args():
    parser = argparse.ArgumentParser(description="Scan Defold assets for broken references.")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Project root (default: repo root two levels up from this script)",
    )
    return parser.parse_args()


def check_exists(path: Path, label: str, missing: list):
    if not path.exists():
        missing.append(f"{label}: {path}")
        return False
    return True


def scan_tilemaps(root: Path, missing: list, warnings: list):
    tm_dir = root / "developer/assets/tiled/maps"
    if not tm_dir.exists():
        warnings.append(f"Tilemaps dir missing: {tm_dir}")
        return
    for tm in sorted(tm_dir.glob("*.tilemap")):
        text = tm.read_text(encoding="utf-8", errors="ignore")
        m = re.search(r'tile_set:\s*"([^"]+)"', text)
        if not m:
            warnings.append(f"No tile_set in {tm.relative_to(root)}")
            continue
        target = m.group(1).lstrip("/")
        tgt_path = root / target
        check_exists(tgt_path, f"tile_set for {tm.relative_to(root)}", missing)


def scan_sprites(root: Path, missing: list):
    sprite_dirs = [
        root / "developer/assets/sprites",
        root / "developer/game",
    ]
    for base in sprite_dirs:
        if not base.exists():
            continue
        for sprite in base.rglob("*.sprite"):
            text = sprite.read_text(encoding="utf-8", errors="ignore")
            m = re.search(r'tile_set:\s*"([^"]+)"', text)
            if not m:
                continue
            target = m.group(1).lstrip("/")
            check_exists(root / target, f"tile_set for {sprite.relative_to(root)}", missing)


def scan_atlases(root: Path, missing: list, warnings: list):
    atlas_dir = root / "developer/assets/atlas"
    if not atlas_dir.exists():
        warnings.append(f"Atlas dir missing: {atlas_dir}")
        return
    for atlas in atlas_dir.glob("*.atlas"):
        text = atlas.read_text(encoding="utf-8", errors="ignore")
        imgs = re.findall(r'image:\s*"([^"]+)"', text)
        if not imgs:
            warnings.append(f"No images referenced in {atlas.relative_to(root)}")
        for img in imgs:
            check_exists(root / img.lstrip("/"), f"atlas image in {atlas.relative_to(root)}", missing)


def main():
    args = load_args()
    root = args.root
    missing = []
    warnings = []

    scan_tilemaps(root, missing, warnings)
    scan_sprites(root, missing)
    scan_atlases(root, missing, warnings)

    if missing:
        print("[FAIL] Missing assets:")
        for m in missing:
            print(" -", m)
    if warnings:
        print("[WARN] Warnings:")
        for w in warnings:
            print(" -", w)
    if not missing and not warnings:
        print("[OK] Asset scan passed (tilemaps, sprites, atlases)")

    if missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
