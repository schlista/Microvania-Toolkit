#!/usr/bin/env python3
"""
Import the repo-local player sprite source pack into Defold-ready flipbook frames.

This replaces the earlier placeholder generator. It slices the sprite sheets
from the repo-local source pack into individual PNG frames under
`/developer/assets/sprites/player/` and regenerates
`/developer/assets/atlas/player.atlas`.

Requirements:
- Python 3
- Pillow (`PIL`)
- Lua (for the shared creator-settings units loader)

Usage:
  py -3.10 developer/tools/generate_player_sprite_frames.py
  py -3.10 developer/tools/generate_player_sprite_frames.py --target-height 224
  py -3.10 developer/tools/generate_player_sprite_frames.py --source "path/to/your/pack"
  py -3.10 developer/tools/generate_player_sprite_frames.py --upscale 4
  py -3.10 developer/tools/generate_player_sprite_frames.py --source "path/to/pack" --keep-geometry

The script will try these source locations automatically:
1) `--source` if provided
2) `/developer/assets/source/player_template/Mannequin` (the colour-coded template)

Sheets marked optional below (swimming, ledge hang, grapple, ladder-climb idle)
may be absent; their animations then fall back to the listed stand-in frames.

A pack may contain a `pack.json` with import settings:
  "baseline_bottom_margin": N  pin every sheet's ground line N source rows above
                               the frame bottom instead of detecting it
  "keep_geometry": true        same as --keep-geometry
  "animations": {id: {...}}    override an animation's "source", "indices",
                               "fps", "playback" or "reverse"

--keep-geometry reuses the canvas, scale and ground line recorded in
player_import_meta.lua and leaves the player prefabs untouched, so new art keeps
the sprite size and offset that the player-scale tooling bakes from.
The default fresh import uses the source pixels 1:1. --fresh-geometry replaces
recorded geometry even when pack.json normally keeps it.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import json
import math
from pathlib import Path
import re
import subprocess

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover - runtime environment dependent
    raise SystemExit(
        "Pillow is required to import the player sprite pack.\n"
        "Run with a Python that has PIL installed, for example:\n"
        "  py -3.10 developer/tools/generate_player_sprite_frames.py"
    ) from exc


ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "developer/assets/sprites/player"
ATLAS_PATH = ROOT / "developer/assets/atlas/player.atlas"
META_PATH = ROOT / "developer/assets/sprites/player/player_import_meta.lua"
PLAYER_SETTINGS_PATH = ROOT / "developer/config/player_settings.lua"
CREATOR_SETTINGS_PATH = ROOT / "developer/config/creator_settings.lua"
PLAYER_PREFAB_PATHS = (
    ROOT / "developer/game/player/player_sprite.go",
    ROOT / "developer/game/player/player_main.go",
)

DEFAULT_COLLIDER_HALF_HEIGHT = 31 * 1.75 * 1.10599
DEFAULT_FOOT_FLOOR_ADJUST = -8 * 1.75 * 1.10599
PLAYER_SPRITE_RENDER_SCALE = 1.0
TEMPLATE_PIXEL_SCALE = 4
REFERENCE_STANDING_SHEET_ID = "idle"

DEFAULT_SOURCE_CANDIDATES = [
    ROOT / "developer/assets/source/player_template/Mannequin",
]


@dataclass(frozen=True)
class SheetSpec:
    id: str
    source_rel: str
    frame_width: int
    frame_height: int
    fps: int
    playback: str
    x_offset: int = 0
    y_offset: int = 0
    baseline_bottom_margin: int | None = None
    # Optional sheets may be missing from a pack (see AnimationSpec.fallback).
    optional: bool = False


@dataclass(frozen=True)
class AnimationSpec:
    id: str
    source_id: str
    fps: int
    playback: str
    indices: tuple[int, ...] | None = None
    # Used when source_id is an optional sheet the pack does not provide:
    # (stand-in sheet id, frame indices or None for every frame).
    fallback: tuple[str, tuple[int, ...] | None] | None = None
    # Play the selected frames last to first (climbing down a ladder).
    reverse: bool = False


@dataclass(frozen=True)
class ImportLayout:
    scale: float
    target_height: int
    reference_visible_height: int
    canvas_width: int
    canvas_height: int
    ground_y: int
    root_x: float
    sheet_baseline_bottom_margins: dict[str, int]


SHEETS: tuple[SheetSpec, ...] = (
    SheetSpec("idle", "Idle/Player Idle 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("walk", "Walk/PlayerWalk 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("run", "Run/player run 192x192.png", 192, 192, 14, "loop"),
    SheetSpec("jump", "Jump/player new jump 192x192.png", 192, 192, 12, "once"),
    SheetSpec("dash", "Dash/dash.png", 192, 192, 18, "once"),
    SheetSpec("death", "Death/Player Death 192x192.png", 192, 192, 10, "once"),
    SheetSpec("hurt_damaged", "Hurt-Damaged/Player Hurt 192x192.png", 192, 192, 12, "once"),
    SheetSpec("land", "Land/player land 192x192.png", 192, 192, 14, "once"),
    SheetSpec("ledge_grab_climb", "Ledge Grab-Climb/player ledge climb 192x192.png", 192, 192, 12, "once"),
    SheetSpec("pull", "Pull/Player Pull 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("punch", "Punch/Player Punch 256x256.png", 256, 256, 14, "once"),
    SheetSpec("punch_cross", "Punch Cross/Player Punch Cross 256x256.png", 256, 256, 14, "once"),
    SheetSpec("punch_jab", "Punch Jab/Player Jab 192x192.png", 192, 192, 16, "once"),
    SheetSpec("push", "Push/player push 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("pushpull_idle_state", "PushPull (idle state)/player push idle 192x192.png", 192, 192, 8, "loop"),
    SheetSpec("roll", "Roll/Player Roll 192x192.png", 192, 192, 16, "once"),
    SheetSpec("running_aiming", "Shooting (running and aiming)/Player Running Aiming 192x192.png", 192, 192, 12, "loop"),
    SheetSpec("running_shooting", "Shooting (running and aiming)/Player Running Shooting 192x192.png", 192, 192, 14, "once"),
    SheetSpec("shooting_two_handed", "Shooting (two-handed)/player shoot 2H 192x192.png", 192, 192, 14, "once"),
    SheetSpec("slide", "Slide/Player Slide 192x192.png", 192, 192, 14, "loop"),
    SheetSpec("sword_attack", "Sword Attack/player sword atk 256x256.png", 256, 256, 14, "once"),
    SheetSpec("sword_idle", "Sword Idle/Player Sword Idle 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("sword_run", "Sword Run/Player Sword Run 192x192.png", 192, 192, 14, "loop"),
    SheetSpec("sword_stab", "Sword Stab/Player Sword Stab 384x192.png", 384, 192, 14, "once"),
    SheetSpec("climb_facing_back_of_player", "Climb (facing back of player)/player climb-back 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("climb_facing_side_of_player", "Climb (facing side of player)/Player Side-Climb 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("crouch_idle", "Crouch-Idle/Player Crouch-Idle 192x192.png", 192, 192, 8, "loop"),
    SheetSpec("crouch_walk", "Crouch-Walk/player crouch-walk 192x192.png", 192, 192, 10, "loop"),
    SheetSpec("air_spin", "Air Spin/player air spin 192x192.png", 192, 192, 14, "once"),
    SheetSpec("wall_land", "Wall Land/player wall land 192x192.png", 192, 192, 12, "once"),
    SheetSpec("wall_slide", "Wall Slide/player wall slide 192x192.png", 192, 192, 8, "loop"),
    SheetSpec("ledge_hang", "Ledge Hang/player ledge hang 192x192.png", 192, 192, 6, "loop", optional=True),
    SheetSpec("climb_back_idle", "Climb Idle (facing back of player)/player climb-back idle 192x192.png",
              192, 192, 6, "loop", optional=True),
    SheetSpec("swim", "Swim/player swim 192x192.png", 192, 192, 10, "loop", optional=True),
    SheetSpec("swim_idle", "Swim Idle/player swim idle 192x192.png", 192, 192, 8, "loop", optional=True),
    SheetSpec("grapple", "Grapple/player grapple 192x192.png", 192, 192, 8, "loop", optional=True),
)

SOURCE_MAX_FRAME_WIDTH = max(spec.frame_width for spec in SHEETS)
SOURCE_MAX_FRAME_HEIGHT = max(spec.frame_height for spec in SHEETS)


ANIMATIONS: tuple[AnimationSpec, ...] = (
    AnimationSpec("idle", "idle", 10, "loop"),
    AnimationSpec("walk", "walk", 10, "loop"),
    AnimationSpec("run", "run", 14, "loop"),
    AnimationSpec("jump", "jump", 12, "once"),
    AnimationSpec("double_jump", "air_spin", 14, "once"),
    AnimationSpec("fall", "jump", 10, "loop", (3, 4, 5)),
    AnimationSpec("land", "land", 14, "once"),
    AnimationSpec("slide", "slide", 14, "loop"),
    AnimationSpec("crouch", "crouch_idle", 8, "loop"),
    AnimationSpec("dash", "dash", 18, "once"),
    AnimationSpec("air_dash", "dash", 18, "once"),
    AnimationSpec("air_dash_right", "dash", 18, "once"),
    AnimationSpec("wall_slide", "wall_slide", 8, "loop"),
    AnimationSpec("wall_cling", "wall_slide", 6, "loop", (0,)),
    AnimationSpec("attack", "punch_jab", 16, "once"),
    AnimationSpec("attack_alt", "punch_cross", 14, "once"),
    AnimationSpec("punch_jab", "punch_jab", 16, "once"),
    AnimationSpec("punch_cross", "punch_cross", 14, "once"),
    AnimationSpec("punch", "punch", 14, "once"),
    AnimationSpec("weapon_attack", "sword_attack", 14, "once"),
    AnimationSpec("shoot", "shooting_two_handed", 14, "once"),
    AnimationSpec("aim", "running_aiming", 12, "loop"),
    AnimationSpec("grapple", "grapple", 8, "loop", fallback=("ledge_grab_climb", (0, 1))),
    AnimationSpec("hurt", "hurt_damaged", 12, "once"),
    AnimationSpec("die", "death", 10, "once"),
    AnimationSpec("death", "death", 10, "once"),
    AnimationSpec("spawn", "idle", 10, "once", (0, 1, 2, 3)),
    AnimationSpec("taunt", "idle", 8, "loop"),
    AnimationSpec("celebrate", "sword_idle", 10, "loop"),
    # Ladders are climbed facing into the screen, so every ladder state uses
    # the back-of-player sheet; the side-climb sheet stays available by id.
    AnimationSpec("climb", "climb_facing_back_of_player", 10, "loop"),
    AnimationSpec("climb_up", "climb_facing_back_of_player", 10, "loop"),
    AnimationSpec("climb_down", "climb_facing_back_of_player", 10, "loop", reverse=True),
    AnimationSpec("climb_idle", "climb_back_idle", 6, "loop", fallback=("climb_facing_back_of_player", (0,))),
    AnimationSpec("hang", "ledge_hang", 6, "loop", fallback=("ledge_grab_climb", (0,))),
    AnimationSpec("swim", "swim", 10, "loop", fallback=("walk", None)),
    AnimationSpec("swim_idle", "swim_idle", 8, "loop", fallback=("idle", None)),
    AnimationSpec("swim_move", "swim", 10, "loop", fallback=("walk", None)),
    AnimationSpec("fly", "run", 14, "loop"),
    AnimationSpec("fly_idle", "idle", 10, "loop"),
    AnimationSpec("fly_move", "run", 14, "loop"),
    AnimationSpec("patrol", "walk", 10, "loop"),
    AnimationSpec("alert", "running_aiming", 10, "loop"),
    AnimationSpec("chase", "run", 14, "loop"),
    AnimationSpec("air_spin", "air_spin", 14, "once"),
    AnimationSpec("climb_facing_back_of_player", "climb_facing_back_of_player", 10, "loop"),
    AnimationSpec("climb_facing_side_of_player", "climb_facing_side_of_player", 10, "loop"),
    AnimationSpec("crouch_idle", "crouch_idle", 8, "loop"),
    AnimationSpec("crouch_walk", "crouch_walk", 10, "loop"),
    AnimationSpec("hurt_damaged", "hurt_damaged", 12, "once"),
    AnimationSpec("ledge_grab_climb", "ledge_grab_climb", 12, "once"),
    AnimationSpec("pull", "pull", 10, "loop"),
    AnimationSpec("push", "push", 10, "loop"),
    AnimationSpec("pushpull_idle_state", "pushpull_idle_state", 8, "loop"),
    AnimationSpec("pull_idle", "pushpull_idle_state", 8, "loop"),
    AnimationSpec("roll", "roll", 16, "once"),
    AnimationSpec("running_aiming", "running_aiming", 12, "loop"),
    AnimationSpec("running_shooting", "running_shooting", 14, "once"),
    AnimationSpec("shooting_two_handed", "shooting_two_handed", 14, "once"),
    AnimationSpec("sword_attack", "sword_attack", 14, "once"),
    AnimationSpec("sword_idle", "sword_idle", 10, "loop"),
    AnimationSpec("sword_run", "sword_run", 14, "loop"),
    AnimationSpec("sword_stab", "sword_stab", 14, "once"),
    AnimationSpec("wall_land", "wall_land", 12, "once"),
)


PLAYBACK_ENUM = {
    "loop": "PLAYBACK_LOOP_FORWARD",
    "once": "PLAYBACK_ONCE_FORWARD",
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=None,
        help="Optional override path to a compatible sprite pack root.",
    )
    parser.add_argument(
        "--upscale",
        type=float,
        default=None,
        help="Override the import scale directly instead of deriving it from --target-height.",
    )
    parser.add_argument(
        "--target-height",
        type=int,
        default=None,
        help="Explicit standing feet-to-head height in pixels; omitted means source pixels are imported 1:1.",
    )
    geometry = parser.add_mutually_exclusive_group()
    geometry.add_argument(
        "--keep-geometry",
        action="store_true",
        help="Reuse the canvas, scale and ground line from player_import_meta.lua and leave the "
             "player prefabs untouched (also enabled by \"keep_geometry\": true in pack.json).",
    )
    geometry.add_argument(
        "--fresh-geometry", action="store_true",
        help="Replace recorded geometry using this source, ignoring pack.json's keep_geometry setting.",
    )
    parser.add_argument(
        "--creator-settings", type=Path, default=CREATOR_SETTINGS_PATH,
        help="Creator document used for Player Size and body alignment (default: the project's saved document).",
    )
    return parser.parse_args(argv)


def resolve_source_root(cli_source: Path | None) -> Path:
    if cli_source is not None and not cli_source.exists():
        # Never fall back to the bundled template when an explicit pack is missing.
        raise SystemExit(f"Player sprite pack not found: {cli_source}")
    candidates: list[Path] = []
    if cli_source is not None:
        candidates.append(cli_source)
    candidates.extend(DEFAULT_SOURCE_CANDIDATES)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    formatted = "\n".join(f"  - {candidate}" for candidate in candidates)
    raise SystemExit(
        "Could not locate the player sprite pack source folder.\n"
        "Checked:\n"
        f"{formatted}\n"
        "Copy the compatible source pack into "
        "'developer/assets/source/player_template/Mannequin' "
        "or pass --source."
    )


PACK_ANIMATION_KEYS = {"source", "indices", "fps", "playback", "reverse"}


def load_pack_settings(source_root: Path) -> dict:
    path = source_root / "pack.json"
    if not path.exists():
        return {}
    settings = json.loads(path.read_text(encoding="utf-8"))
    margin = settings.get("baseline_bottom_margin")
    if margin is not None and (not isinstance(margin, int) or margin < 0):
        raise SystemExit(f"{path}: baseline_bottom_margin must be a non-negative integer")
    for anim_id, override in (settings.get("animations") or {}).items():
        unknown = set(override) - PACK_ANIMATION_KEYS
        if unknown:
            raise SystemExit(f"{path}: animation '{anim_id}' has unknown keys {sorted(unknown)}")
        if "playback" in override and override["playback"] not in PLAYBACK_ENUM:
            raise SystemExit(f"{path}: animation '{anim_id}' playback must be one of {sorted(PLAYBACK_ENUM)}")
    return settings


def active_sheets(source_root: Path, settings: dict) -> list[SheetSpec]:
    """Sheets present in the pack, with the pack's pinned baseline applied."""
    margin = settings.get("baseline_bottom_margin")
    sheets: list[SheetSpec] = []
    missing: list[str] = []
    for spec in SHEETS:
        if not (source_root / spec.source_rel).exists():
            if not spec.optional:
                missing.append(spec.source_rel)
            continue
        if margin is not None and spec.baseline_bottom_margin is None:
            spec = replace(spec, baseline_bottom_margin=margin)
        sheets.append(spec)
    if missing:
        raise SystemExit("Player sprite pack is missing required sheets:\n  " + "\n  ".join(missing))
    return sheets


def resolve_animations(settings: dict, available: set[str]) -> list[AnimationSpec]:
    """Apply pack.json overrides, then fall back for optional sheets the pack lacks."""
    overrides = dict(settings.get("animations") or {})
    resolved: list[AnimationSpec] = []
    for anim in ANIMATIONS:
        override = overrides.pop(anim.id, None)
        if override:
            anim = replace(
                anim,
                source_id=override.get("source", anim.source_id),
                indices=tuple(override["indices"]) if "indices" in override else anim.indices,
                fps=int(override.get("fps", anim.fps)),
                playback=override.get("playback", anim.playback),
                reverse=bool(override.get("reverse", anim.reverse)),
            )
        if anim.source_id not in available:
            if anim.fallback is None or anim.fallback[0] not in available:
                raise SystemExit(f"Animation '{anim.id}' needs sheet '{anim.source_id}', which the pack lacks")
            anim = replace(anim, source_id=anim.fallback[0], indices=anim.fallback[1])
        resolved.append(anim)
    if overrides:
        raise SystemExit("pack.json overrides unknown animations: " + ", ".join(sorted(overrides)))
    return resolved


def read_import_meta() -> dict[str, float]:
    if not META_PATH.exists():
        raise SystemExit(f"--keep-geometry needs an existing {META_PATH.relative_to(ROOT)}")
    values = {}
    for key, value in re.findall(r"^\s*(\w+)\s*=\s*(-?\d+(?:\.\d+)?)\s*,", META_PATH.read_text(encoding="utf-8"), re.M):
        values[key] = float(value)
    needed = ("scale", "target_height", "reference_visible_height", "canvas_width", "canvas_height",
              "ground_y", "root_x")
    absent = [key for key in needed if key not in values]
    if absent:
        raise SystemExit(f"{META_PATH.relative_to(ROOT)} lacks {', '.join(absent)}")
    return values


def layout_from_meta(source_root: Path, sheets: list[SheetSpec], meta: dict[str, float]) -> ImportLayout:
    scale = meta["scale"]
    baselines: dict[str, int] = {}
    for spec in sheets:
        with Image.open(source_root / spec.source_rel) as image:
            baselines[spec.id] = detect_sheet_baseline_bottom_margin(image.convert("RGBA"), spec, scale)
    return ImportLayout(
        scale=scale,
        target_height=int(meta["target_height"]),
        reference_visible_height=int(meta["reference_visible_height"]),
        canvas_width=int(meta["canvas_width"]),
        canvas_height=int(meta["canvas_height"]),
        ground_y=int(meta["ground_y"]),
        root_x=meta["root_x"],
        sheet_baseline_bottom_margins=baselines,
    )


def clean_output_dir() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for path in OUT_DIR.glob("*.png"):
        path.unlink()


def read_player_body_settings() -> tuple[float, float, float]:
    """Player Size, collider half-height and foot floor adjust (base pixels).

    Uses the same units migration as runtime before reading published settings.
    The Lua reader never writes either input. This avoids a second implementation
    of old-unit document migration in the Python art importer.
    """
    if not PLAYER_SETTINGS_PATH.exists():
        return 1.0, float(DEFAULT_COLLIDER_HALF_HEIGHT), float(DEFAULT_FOOT_FLOOR_ADJUST)
    if not CREATOR_SETTINGS_PATH.exists():
        text = PLAYER_SETTINGS_PATH.read_text(encoding="utf-8")
        def number(key: str, fallback: float) -> float:
            match = re.search(rf"\b{key}\s*=\s*(-?\d+(?:\.\d+)?)", text)
            return float(match.group(1)) if match else fallback
        return (number("player_scale", 1.0), number("collider_half_height", DEFAULT_COLLIDER_HALF_HEIGHT),
                number("foot_floor_adjust", DEFAULT_FOOT_FLOOR_ADJUST))
    reader = r'''
local Model = require "mvtk.core.creator_settings_model"
local Scale = require "mvtk.player.player_scale"
local player = dofile(arg[1])
local doc = Model.load_document(dofile(arg[2]), player)
if doc.published == true then Model.merge(player, doc.overrides.player or {}) end
local scale = math.max(Scale.MIN_SCALE, math.min(Scale.MAX_SCALE, player.player_scale or 1))
io.write(string.format("%.17g\n%.17g\n%.17g\n", scale, player.collider_half_height, player.foot_floor_adjust or 0))
'''
    result = subprocess.run(
        ["lua", "-", str(PLAYER_SETTINGS_PATH), str(CREATOR_SETTINGS_PATH)],
        input=reader, text=True, capture_output=True, cwd=ROOT,
    )
    if result.returncode != 0:
        raise RuntimeError("Could not load player art size settings:\n" + result.stderr.strip())
    scale, half_height, foot_adjust = (float(value) for value in result.stdout.splitlines())
    if not math.isfinite(scale) or scale <= 0 or not math.isfinite(half_height) or half_height <= 0:
        raise ValueError("Player Size and collider half-height must be finite and positive")
    if not math.isfinite(foot_adjust):
        raise ValueError("foot_floor_adjust must be a finite number")
    return scale, half_height, foot_adjust


def read_player_size_settings() -> tuple[float, float]:
    scale, half_height, _ = read_player_body_settings()
    return scale, half_height


def read_player_collider_half_height() -> float:
    return read_player_size_settings()[1]


def read_player_foot_floor_adjust() -> float:
    return read_player_body_settings()[2]


def read_player_foot_y() -> float:
    """Base-pixel height of the standing feet below the player origin.

    Matches the runtime (movement.lua, bone_physics.lua): the body stands with
    its collider bottom plus foot_floor_adjust on the floor, so drawn feet must
    land there, not on the collider bottom.
    """
    _, half_height, foot_adjust = read_player_body_settings()
    return -half_height + foot_adjust


def read_player_scale() -> float:
    return read_player_size_settings()[0]


def format_defold_number(value: float) -> str:
    if abs(value - round(value)) < 0.0001:
        return f"{value:.1f}"
    return f"{value:.2f}".rstrip("0").rstrip(".")


def scaled_dimensions(spec: SheetSpec, scale: float) -> tuple[int, int]:
    return (
        max(1, int(round(spec.frame_width * scale))),
        max(1, int(round(spec.frame_height * scale))),
    )


def detect_sheet_baseline_bottom_margin(image: Image.Image, spec: SheetSpec, scale: float = 1.0) -> int:
    if spec.baseline_bottom_margin is not None:
        return int(round(spec.baseline_bottom_margin * scale))

    width, _ = image.size
    columns = width // spec.frame_width
    margins: list[int] = []
    scaled_frame_width, scaled_frame_height = scaled_dimensions(spec, scale)
    for index in range(columns):
        left = index * spec.frame_width
        box = (left, 0, left + spec.frame_width, spec.frame_height)
        frame = image.crop(box)
        if scale != 1.0:
            frame = frame.resize((scaled_frame_width, scaled_frame_height), Image.NEAREST)
        alpha_bbox = frame.getchannel("A").getbbox()
        if alpha_bbox is None:
            continue
        margins.append(scaled_frame_height - alpha_bbox[3])
    return min(margins) if margins else 0


def detect_reference_visible_height(source_root: Path) -> int:
    reference_spec = next((spec for spec in SHEETS if spec.id == REFERENCE_STANDING_SHEET_ID), None)
    if reference_spec is None:
        raise RuntimeError(f"Missing reference sheet '{REFERENCE_STANDING_SHEET_ID}' in SHEETS")

    source_path = source_root / reference_spec.source_rel
    with Image.open(source_path) as image:
        image = image.convert("RGBA")
        columns = image.size[0] // reference_spec.frame_width
        heights: list[int] = []
        for index in range(columns):
            left = index * reference_spec.frame_width
            box = (left, 0, left + reference_spec.frame_width, reference_spec.frame_height)
            frame = image.crop(box)
            alpha_bbox = frame.getchannel("A").getbbox()
            if alpha_bbox is not None:
                heights.append(alpha_bbox[3] - alpha_bbox[1])
    if not heights:
        raise RuntimeError(f"Could not measure visible height from {source_path}")
    return max(heights)


def measure_reference_scaled_height(source_root: Path, scale: float) -> int:
    reference_spec = next((spec for spec in SHEETS if spec.id == REFERENCE_STANDING_SHEET_ID), None)
    if reference_spec is None:
        raise RuntimeError(f"Missing reference sheet '{REFERENCE_STANDING_SHEET_ID}' in SHEETS")

    source_path = source_root / reference_spec.source_rel
    scaled_frame_width, scaled_frame_height = scaled_dimensions(reference_spec, scale)
    max_height = 0
    with Image.open(source_path) as image:
        image = image.convert("RGBA")
        columns = image.size[0] // reference_spec.frame_width
        for index in range(columns):
            left = index * reference_spec.frame_width
            box = (left, 0, left + reference_spec.frame_width, reference_spec.frame_height)
            frame = image.crop(box)
            if scale != 1.0:
                frame = frame.resize((scaled_frame_width, scaled_frame_height), Image.NEAREST)
            alpha_bbox = frame.getchannel("A").getbbox()
            if alpha_bbox is not None:
                max_height = max(max_height, alpha_bbox[3] - alpha_bbox[1])
    if max_height <= 0:
        raise RuntimeError(f"Could not measure scaled visible height from {source_path}")
    return max_height


def resolve_target_height_scale(source_root: Path, target_height: int, reference_visible_height: int) -> float:
    initial_scale = float(target_height) / float(reference_visible_height)
    measured = measure_reference_scaled_height(source_root, initial_scale)
    if measured == target_height:
        return initial_scale

    if measured < target_height:
        low = initial_scale
        high = initial_scale
        while measure_reference_scaled_height(source_root, high) < target_height:
            high *= 1.02
        for _ in range(24):
            mid = (low + high) * 0.5
            if measure_reference_scaled_height(source_root, mid) < target_height:
                low = mid
            else:
                high = mid
        return high

    low = initial_scale
    high = initial_scale
    while measure_reference_scaled_height(source_root, low) > target_height:
        low *= 0.98
    for _ in range(24):
        mid = (low + high) * 0.5
        if measure_reference_scaled_height(source_root, mid) > target_height:
            high = mid
        else:
            low = mid
    return low


def resolve_import_layout(source_root: Path, args: argparse.Namespace, sheets: list[SheetSpec]) -> ImportLayout:
    reference_visible_height = detect_reference_visible_height(source_root)
    scale = (
        float(args.upscale)
        if args.upscale is not None
        else (resolve_target_height_scale(source_root, int(args.target_height), reference_visible_height)
              if args.target_height is not None else 1.0)
    )

    max_left = 0.0
    max_right = 0.0
    max_above = 0.0
    max_below = 0.0
    sheet_baselines: dict[str, int] = {}

    for spec in sheets:
        source_path = source_root / spec.source_rel
        with Image.open(source_path) as image:
            image = image.convert("RGBA")
            width, height = image.size
            if width < spec.frame_width or height < spec.frame_height:
                raise ValueError(f"Sheet smaller than frame size for {spec.id}: {source_path}")
            columns = width // spec.frame_width
            if columns <= 0:
                raise ValueError(f"No frames detected for {spec.id}: {source_path}")

            scaled_frame_width, scaled_frame_height = scaled_dimensions(spec, scale)
            baseline_bottom_margin = detect_sheet_baseline_bottom_margin(image, spec, scale)
            sheet_baselines[spec.id] = baseline_bottom_margin

            x_offset = spec.x_offset * scale
            y_offset = spec.y_offset * scale
            frame_center_x = scaled_frame_width * 0.5

            for index in range(columns):
                left = index * spec.frame_width
                box = (left, 0, left + spec.frame_width, spec.frame_height)
                frame = image.crop(box)
                if scale != 1.0:
                    frame = frame.resize((scaled_frame_width, scaled_frame_height), Image.NEAREST)
                alpha_bbox = frame.getchannel("A").getbbox()
                if alpha_bbox is None:
                    continue

                bbox_left, bbox_top, bbox_right, bbox_bottom = alpha_bbox
                max_left = max(max_left, frame_center_x - bbox_left - x_offset)
                max_right = max(max_right, bbox_right - frame_center_x + x_offset)
                max_above = max(
                    max_above,
                    (scaled_frame_height - baseline_bottom_margin) - bbox_top - y_offset,
                )
                max_below = max(
                    max_below,
                    bbox_bottom + y_offset - (scaled_frame_height - baseline_bottom_margin),
                )

    max_half_width = max(max_left, max_right)
    canvas_width = int(math.ceil(max_half_width) * 2)
    root_x = canvas_width * 0.5

    return ImportLayout(
        scale=scale,
        target_height=(int(args.target_height) if args.target_height is not None
                       else measure_reference_scaled_height(source_root, scale)),
        reference_visible_height=reference_visible_height,
        canvas_width=canvas_width,
        canvas_height=int(math.ceil(max_above + max_below)),
        ground_y=int(math.ceil(max_above)),
        root_x=root_x,
        sheet_baseline_bottom_margins=sheet_baselines,
    )


def slice_sheet(source_root: Path, spec: SheetSpec, layout: ImportLayout, clipped: list[str]) -> list[Path]:
    source_path = source_root / spec.source_rel
    if not source_path.exists():
        raise FileNotFoundError(f"Missing source sheet: {source_path}")

    scaled_frame_width, scaled_frame_height = scaled_dimensions(spec, layout.scale)

    with Image.open(source_path) as image:
        image = image.convert("RGBA")
        width, height = image.size
        if spec.frame_width <= 0 or spec.frame_height <= 0:
            raise ValueError(f"Invalid frame size for {spec.id}")
        if width < spec.frame_width or height < spec.frame_height:
            raise ValueError(f"Sheet smaller than frame size for {spec.id}: {source_path}")
        columns = width // spec.frame_width
        if columns <= 0:
            raise ValueError(f"No frames detected for {spec.id}: {source_path}")
        baseline_bottom_margin = layout.sheet_baseline_bottom_margins[spec.id]
        x_offset = int(round(spec.x_offset * layout.scale))
        y_offset = int(round(spec.y_offset * layout.scale))

        written: list[Path] = []
        for index in range(columns):
            left = index * spec.frame_width
            box = (left, 0, left + spec.frame_width, spec.frame_height)
            frame = image.crop(box)
            if layout.scale != 1.0:
                frame = frame.resize((scaled_frame_width, scaled_frame_height), Image.NEAREST)

            canvas = Image.new("RGBA", (layout.canvas_width, layout.canvas_height), (0, 0, 0, 0))
            dest_x = int(round(layout.root_x - (scaled_frame_width * 0.5) + x_offset))
            dest_y = int(round(layout.ground_y - scaled_frame_height + baseline_bottom_margin + y_offset))
            canvas.paste(frame, (dest_x, dest_y), frame)
            source_box = frame.getchannel("A").getbbox()
            if source_box is not None:
                left, top = dest_x + source_box[0], dest_y + source_box[1]
                right, bottom = dest_x + source_box[2], dest_y + source_box[3]
                if left < 0 or top < 0 or right > layout.canvas_width or bottom > layout.canvas_height:
                    clipped.append(f"{spec.id}_{index + 1:02d}")

            out_path = OUT_DIR / f"{spec.id}_{index + 1:02d}.png"
            canvas.save(out_path)
            written.append(out_path)
        return written


def write_atlas(image_sets: dict[str, list[Path]], animations: list[AnimationSpec]) -> None:
    lines = [
        "extrude_borders: 0",
        "inner_padding: 0",
        "max_page_width: 0",
        "max_page_height: 0",
        "",
        "# Generated by /developer/tools/generate_player_sprite_frames.py",
        "# Imported from the player sprite source pack under /developer/assets/source/player_template/.",
        "# Keep canonical ids stable; extra gameplay ids are added for optional use.",
        "",
    ]

    for anim in animations:
        source_frames = image_sets[anim.source_id]
        indices = anim.indices if anim.indices is not None else tuple(range(len(source_frames)))
        if not indices:
            raise ValueError(f"Animation {anim.id} has no frame indices")
        out_of_range = [index for index in indices if not 0 <= index < len(source_frames)]
        if out_of_range:
            raise ValueError(f"Animation {anim.id} uses frames {out_of_range} but "
                             f"'{anim.source_id}' has {len(source_frames)}")
        frames = [source_frames[index] for index in indices]
        if anim.reverse:
            frames.reverse()

        lines.append("animations {")
        lines.append(f'  id: "{anim.id}"')
        for frame in frames:
            rel = "/" + frame.relative_to(ROOT).as_posix()
            lines.append("  images {")
            lines.append(f'    image: "{rel}"')
            lines.append("    sprite_trim_mode: SPRITE_TRIM_MODE_OFF")
            lines.append("  }")
        lines.append(f"  playback: {PLAYBACK_ENUM[anim.playback]}")
        lines.append(f"  fps: {anim.fps}")
        lines.append("  flip_horizontal: 0")
        lines.append("  flip_vertical: 0")
        lines.append("}")
        lines.append("")

    with ATLAS_PATH.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines).rstrip() + "\n")


def sprite_offset_y_for_layout(layout: ImportLayout) -> float:
    foot_world_y = read_player_foot_y()
    ground_to_center = layout.ground_y - (layout.canvas_height * 0.5)
    return (foot_world_y + ground_to_center * PLAYER_SPRITE_RENDER_SCALE) * read_player_scale()


def sprite_manual_size_for_layout(layout: ImportLayout) -> tuple[float, float]:
    return (
        layout.canvas_width * PLAYER_SPRITE_RENDER_SCALE * read_player_scale(),
        layout.canvas_height * PLAYER_SPRITE_RENDER_SCALE * read_player_scale(),
    )


def write_import_meta(layout: ImportLayout) -> None:
    collider_half_height = read_player_collider_half_height()
    foot_floor_adjust = read_player_foot_floor_adjust()
    player_scale = read_player_scale()
    foot_world_y = read_player_foot_y() * player_scale
    sprite_offset_y = sprite_offset_y_for_layout(layout)
    sprite_size_width, sprite_size_height = sprite_manual_size_for_layout(layout)
    lines = [
        "-- Generated by /developer/tools/generate_player_sprite_frames.py",
        "-- Defines the sprite visual offset for the baked player frames.",
        "return {",
        f"  scale = {layout.scale},",
        f"  target_height = {layout.target_height},",
        f"  reference_visible_height = {layout.reference_visible_height},",
        f"  canvas_width = {layout.canvas_width},",
        f"  canvas_height = {layout.canvas_height},",
        f"  ground_y = {layout.ground_y},",
        f"  root_x = {layout.root_x},",
        f"  sprite_render_scale = {PLAYER_SPRITE_RENDER_SCALE},",
        "  -- Player Size used for the baked sprite; unitless, safe range 1/7 to 8.",
        f"  player_scale = {player_scale},",
        f"  sprite_size_width = {format_defold_number(sprite_size_width)},",
        f"  sprite_size_height = {format_defold_number(sprite_size_height)},",
        f"  collider_half_height = {collider_half_height},",
        "  -- Feet line below the origin: -collider_half_height + foot_floor_adjust, times Player Size.",
        f"  foot_floor_adjust = {foot_floor_adjust},",
        f"  foot_world_y = {foot_world_y},",
        f"  sprite_offset_y = {sprite_offset_y},",
        "}",
        "",
    ]
    with META_PATH.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines))


def sprite_size_data_block(layout: ImportLayout) -> str:
    width, height = sprite_manual_size_for_layout(layout)
    return "\n".join([
        '  "size {\\n"',
        f'  "  x: {format_defold_number(width)}\\n"',
        f'  "  y: {format_defold_number(height)}\\n"',
        '  "}\\n"',
        '  "size_mode: SIZE_MODE_MANUAL\\n"',
        "",
    ])


def update_player_prefab_size(source: str, layout: ImportLayout) -> str:
    size_block = sprite_size_data_block(layout)
    size_pattern = re.compile(
        r'\s*"size \{\\n"\n'
        r'\s*"  x: -?\d+(?:\.\d+)?\\n"\n'
        r'\s*"  y: -?\d+(?:\.\d+)?\\n"\n'
        r'\s*"\}\\n"\n'
        r'\s*"size_mode: SIZE_MODE_MANUAL\\n"\n',
    )
    updated, count = size_pattern.subn(lambda _match: "\n" + size_block, source, count=1)
    if count == 1:
        return updated

    insert_pattern = re.compile(
        r'(embedded_components \{\n\s*id: "sprite"\n.*?  "\}\\n"\n)(\s*position \{\n)',
        re.S,
    )
    updated, count = insert_pattern.subn(
        lambda match: match.group(1) + size_block + match.group(2),
        source,
        count=1,
    )
    if count != 1:
        raise RuntimeError("Could not update sprite manual size block")
    return updated


def update_player_prefab_alignment(layout: ImportLayout) -> float:
    target_y = sprite_offset_y_for_layout(layout)
    pattern = re.compile(
        r'(embedded_components \{\n\s*id: "sprite"\n.*?position \{\n\s*y: )(-?\d+(?:\.\d+)?)(\n\s*\}\n)',
        re.S,
    )
    replacement_value = format_defold_number(target_y)
    for path in PLAYER_PREFAB_PATHS:
        source = path.read_text(encoding="utf-8")
        updated, count = pattern.subn(rf"\g<1>{replacement_value}\g<3>", source, count=1)
        if count != 1:
            raise RuntimeError(f"Could not update sprite position block in {path}")
        updated = update_player_prefab_size(updated, layout)
        path.write_text(updated, encoding="utf-8", newline="\n")
    return target_y


def main() -> None:
    global CREATOR_SETTINGS_PATH
    args = parse_args()
    CREATOR_SETTINGS_PATH = args.creator_settings.resolve()
    if args.upscale is not None and args.upscale <= 0:
        raise SystemExit("--upscale must be greater than 0.")
    if args.target_height is not None and args.target_height < 1:
        raise SystemExit("--target-height must be at least 1.")
    source_root = resolve_source_root(args.source)
    settings = load_pack_settings(source_root)
    keep_geometry = args.keep_geometry or (bool(settings.get("keep_geometry")) and not args.fresh_geometry)
    if keep_geometry and args.upscale is not None:
        raise SystemExit("--keep-geometry reuses the recorded scale; do not combine it with --upscale.")
    sheets = active_sheets(source_root, settings)
    animations = resolve_animations(settings, {spec.id for spec in sheets})
    if keep_geometry:
        layout = layout_from_meta(source_root, sheets, read_import_meta())
    else:
        layout = resolve_import_layout(source_root, args, sheets)

    # Everything is validated above, so the output folder is only cleared once
    # the import is known to succeed.
    clean_output_dir()
    image_sets: dict[str, list[Path]] = {}
    clipped: list[str] = []
    for spec in sheets:
        image_sets[spec.id] = slice_sheet(source_root, spec, layout, clipped)

    write_atlas(image_sets, animations)
    print(f"Imported player sprite source from: {source_root}")
    print(f"Wrote frames to: {OUT_DIR}")
    print(f"Wrote atlas to: {ATLAS_PATH}")
    if keep_geometry:
        print(f"Kept the recorded sprite geometry from: {META_PATH}")
    else:
        write_import_meta(layout)
        sprite_offset_y = update_player_prefab_alignment(layout)
        print(f"Wrote import metadata to: {META_PATH}")
        print(f"Updated player sprite prefab offset to y={sprite_offset_y:.2f}")
    print(f"Resolved import scale: {layout.scale:.4f}x")
    print(f"Standing target height: {layout.target_height}px (reference source height {layout.reference_visible_height}px)")
    print(f"Output frame canvas: {layout.canvas_width}x{layout.canvas_height}")
    skipped = [spec.id for spec in SHEETS if spec.optional and spec.id not in image_sets]
    if skipped:
        print(f"Optional sheets not in this pack (stand-in frames used): {', '.join(skipped)}")
    if clipped:
        print(f"WARNING: {len(clipped)} frames extend past the kept canvas and were cropped: "
              + ", ".join(clipped))
    print(f"Generated {sum(len(paths) for paths in image_sets.values())} frame PNGs across {len(sheets)} source animations.")


if __name__ == "__main__":
    main()
