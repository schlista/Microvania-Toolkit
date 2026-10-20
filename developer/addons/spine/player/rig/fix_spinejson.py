#!/usr/bin/env python3
"""Prepare a Spine JSON export for Defold's loose-image atlas workflow."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_IMAGES_DIR = SCRIPT_DIR / "buck"
DEFAULT_OUTPUT = DEFAULT_IMAGES_DIR / "buck.spinejson"
NON_IMAGE_ATTACHMENT_TYPES = {"boundingbox", "clipping", "path", "point"}


def image_basename(value: str) -> str:
    """Return the final component of either a Spine '/' path or Windows path."""
    return value.replace("\\", "/").rsplit("/", 1)[-1]


def png_name(image_ref: str) -> str:
    """Convert an extensionless Spine image reference to its PNG filename."""
    name = image_basename(image_ref)
    return name if name.lower().endswith(".png") else f"{name}.png"


def attachment_maps(data: dict[str, Any]) -> Iterable[dict[str, Any]]:
    """Yield slot-to-attachment maps from Spine 4.x and older JSON layouts."""
    skins = data.get("skins", [])
    if isinstance(skins, list):
        for skin in skins:
            if isinstance(skin, dict) and isinstance(skin.get("attachments"), dict):
                yield skin["attachments"]
    elif isinstance(skins, dict):
        for skin in skins.values():
            if not isinstance(skin, dict):
                continue
            attachments = skin.get("attachments", skin)
            if isinstance(attachments, dict):
                yield attachments


def flatten_attachment_image_refs(data: dict[str, Any]) -> tuple[set[str], int]:
    """Flatten only attachment image fields, leaving rig and animation names intact."""
    image_refs: set[str] = set()
    flattened = 0

    for slots in attachment_maps(data):
        for attachments in slots.values():
            if not isinstance(attachments, dict):
                continue
            for attachment_name, attachment in attachments.items():
                if not isinstance(attachment, dict):
                    continue

                attachment_type = attachment.get("type", "region")
                if attachment_type in NON_IMAGE_ATTACHMENT_TYPES:
                    continue

                explicit_refs: list[str] = []
                for field in ("path", "name"):
                    value = attachment.get(field)
                    if not isinstance(value, str) or not value:
                        continue
                    flattened_value = image_basename(value)
                    if flattened_value != value:
                        attachment[field] = flattened_value
                        flattened += 1
                    explicit_refs.append(flattened_value)

                # A linked mesh without its own path inherits its parent's image.
                if not explicit_refs and attachment_type == "linkedmesh":
                    continue

                refs = explicit_refs or [str(attachment_name)]
                image_refs.update(png_name(ref) for ref in refs)

    return image_refs, flattened


def bake_root_scale(data: dict[str, Any], scale: float) -> tuple[str, int]:
    """Bake the root scale into the setup pose AND remove root scale timelines.

    The rig is shrunk by scaling the root bone's setup pose. That is not enough
    on its own: Defold's Spine runtime applies scale timelines as ABSOLUTE
    values, so any animation that keys the root bone's scale (e.g. Melee_Swing2/3
    key it to 1.0) throws away the baked shrink mid-clip and the character blows
    up to full size ("stretched across the screen"). The exported root scale
    keys are neutral auto-keys (all 1.0) with no animation intent, so stripping
    them is safe and lets the baked setup scale hold for the whole clip.

    Returns (root_bone_name, number_of_root_scale_timelines_removed).
    """
    bones = data.get("bones")
    if not isinstance(bones, list) or not bones:
        raise ValueError("Spine JSON has no bones")

    root = next(
        (bone for bone in bones if isinstance(bone, dict) and "parent" not in bone),
        None,
    )
    if root is None:
        raise ValueError("Spine JSON has no root bone")

    for field in ("scaleX", "scaleY"):
        value = root.get(field, 1.0)
        if not isinstance(value, (int, float)):
            raise ValueError(f"root bone {field} must be numeric")
        root[field] = value * scale

    root_name = str(root.get("name", "<unnamed>"))

    removed = 0
    animations = data.get("animations")
    if isinstance(animations, dict):
        for anim_name, anim in animations.items():
            if not isinstance(anim, dict):
                continue
            root_timelines = (anim.get("bones") or {}).get(root_name)
            if not isinstance(root_timelines, dict):
                continue
            scale_tl = root_timelines.get("scale")
            if scale_tl is None:
                continue
            for key in scale_tl if isinstance(scale_tl, list) else []:
                if isinstance(key, dict):
                    kx, ky = key.get("x", 1.0), key.get("y", 1.0)
                    if kx != 1.0 or ky != 1.0:
                        print(
                            f"warning: '{anim_name}' root.scale key is non-neutral "
                            f"({kx}, {ky}); removing it changes the animation.",
                            file=sys.stderr,
                        )
            del root_timelines["scale"]
            removed += 1

    return root_name, removed


def validate_images(image_refs: set[str], images_dir: Path) -> tuple[set[str], set[str]]:
    if not images_dir.is_dir():
        raise ValueError(f"image directory does not exist: {images_dir}")

    pngs = {path.name for path in images_dir.iterdir() if path.is_file() and path.suffix.lower() == ".png"}
    missing = image_refs - pngs
    unused = pngs - image_refs

    print(f"Image references: {len(image_refs)}")
    print(f"PNGs: {len(pngs)}")
    print("Missing PNGs: " + (", ".join(sorted(missing)) if missing else "none"))
    print("Unused PNGs: " + (", ".join(sorted(unused)) if unused else "none"))
    return missing, unused


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Flatten Spine attachment image paths, bake root scale, validate the "
            "loose PNG set, and write a Defold .spinejson resource."
        )
    )
    parser.add_argument("input", type=Path, help="Spine JSON export to process")
    parser.add_argument(
        "--scale",
        type=float,
        default=0.483870,
        help="root-bone scale multiplier (default: 0.483870)",
    )
    parser.add_argument(
        "--images-dir",
        type=Path,
        default=DEFAULT_IMAGES_DIR,
        help=f"directory containing attachment PNGs (default: {DEFAULT_IMAGES_DIR})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"output .spinejson path (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()
    if not math.isfinite(args.scale) or args.scale <= 0:
        parser.error("--scale must be a finite number greater than zero")
    return args


def main() -> int:
    args = parse_args()
    try:
        with args.input.open("r", encoding="utf-8") as source:
            data = json.load(source)
        if not isinstance(data, dict):
            raise ValueError("Spine JSON root must be an object")

        image_refs, flattened = flatten_attachment_image_refs(data)
        if not image_refs:
            raise ValueError("Spine JSON contains no attachment image references")
        root_name, root_scale_tl_removed = bake_root_scale(data, args.scale)
        missing, unused = validate_images(image_refs, args.images_dir)
        if missing or unused:
            print("Image validation failed; output was not written.", file=sys.stderr)
            return 1

        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", encoding="utf-8", newline="\n") as destination:
            json.dump(data, destination, ensure_ascii=False, indent="\t")
            destination.write("\n")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Flattened attachment fields: {flattened}")
    print(f"Root bone '{root_name}' scale multiplier: {args.scale:g}")
    print(f"Root scale timelines removed from animations: {root_scale_tl_removed}")
    print(f"Wrote: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
