#!/usr/bin/env python3
"""
Draw the "Wayfarer" player model: a complete pixel-art source pack for the
sprite player, then (by default) import it into the game.

The pack uses the folder and sheet layout that
`generate_player_sprite_frames.py` reads (its SHEETS list), including the
optional sheets (swimming, ledge hang, grapple and a ladder-climb idle).

`--mannequin` draws the same skeleton and poses as a plain, colour-coded
figure instead (head and hands, torso and arms, legs, feet; no costume) into
`developer/assets/source/player_template/Mannequin`. That pack is the template
creators copy when they draw their own player; it is not imported.

Every frame is drawn from one small 2D skeleton (side view and back view), so
all animations share one consistent model:
  - limbs are posed with angles or two-bone IK and rasterized as shaded capsules,
  - the head, hair and face come from hand-authored pixel templates,
  - overlapping parts get a dark separation line, then a 1px outline is added,
  - effects (slashes, dust, bubbles, muzzle flashes) are drawn without outline.

Ladder climbing is drawn from behind (back of the head, backpack and scarf
visible); wall climbing keeps a side view.

Requirements: Python 3.10+ and Pillow (`py -m pip install Pillow`).

Usage (from the project root):
  py developer/tools/generate_player_model_pack.py            # draw + import
  py developer/tools/generate_player_model_pack.py --no-import
  py developer/tools/generate_player_model_pack.py --preview preview.png
  py developer/tools/generate_player_model_pack.py --mannequin  # template only

Import runs `generate_player_sprite_frames.py --source <pack> --keep-geometry`
so the sprite keeps the canvas size and offset that player scaling expects.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover - runtime environment dependent
    raise SystemExit("Pillow is required: py -m pip install Pillow") from exc


ROOT = Path(__file__).resolve().parents[2]
PACK_DIR = ROOT / "developer/assets/source/player_template/Wayfarer"
MANNEQUIN_DIR = ROOT / "developer/assets/source/player_template/Mannequin"
IMPORTER = ROOT / "developer/tools/generate_player_sprite_frames.py"
# Set by use_mannequin(): draw the plain colour-coded template, no costume.
MANNEQUIN = False

# Rows kept empty under the ground line in every frame. The importer pins the
# sheet baseline to this margin (pack.json), so airborne frames stay where they
# are drawn relative to the body instead of being dropped onto the ground.
BOTTOM_MARGIN = 8
# The pinned import canvas holds 40 source rows above the ground line and
# 41 source columns either side of the frame centre (player_import_meta.lua).
MAX_ROWS_ABOVE_GROUND = 40
MAX_HALF_WIDTH = 41


# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------
# Each material is (highlight, base, shadow, dark). Far limbs drop one step.

def rgb(hex_value: str) -> tuple[int, int, int, int]:
    hex_value = hex_value.lstrip("#")
    return (int(hex_value[0:2], 16), int(hex_value[2:4], 16), int(hex_value[4:6], 16), 255)


MATERIALS: dict[str, tuple] = {
    "hair": tuple(rgb(c) for c in ("#9a5c3e", "#68402e", "#462826", "#2e1a20")),
    "skin": tuple(rgb(c) for c in ("#ffdcb4", "#f0b888", "#cc8462", "#965848")),
    "tunic": tuple(rgb(c) for c in ("#62c8aa", "#2c968a", "#1c666c", "#164250")),
    "pants": tuple(rgb(c) for c in ("#58689c", "#3c4676", "#2a2e56", "#1e1e3c")),
    "boot": tuple(rgb(c) for c in ("#aa7042", "#805032", "#583628", "#3c2420")),
    "scarf": tuple(rgb(c) for c in ("#ff885c", "#e24e3e", "#a42e36", "#6e1e2e")),
    "pack": tuple(rgb(c) for c in ("#d6ba84", "#b09262", "#826848", "#5c4634")),
    "belt": tuple(rgb(c) for c in ("#7a5034", "#5a3826", "#42281e", "#2e1c18")),
    "blade": tuple(rgb(c) for c in ("#ffffff", "#c8d6e8", "#8090b0", "#4c5674")),
    "guard": tuple(rgb(c) for c in ("#ffe08c", "#f4c450", "#c08a34", "#7a5428")),
    "grip": tuple(rgb(c) for c in ("#8c5a3c", "#6e402c", "#4e2c22", "#341e1a")),
    "gun": tuple(rgb(c) for c in ("#aab4c8", "#6e768c", "#464a60", "#2c2e40")),
}
# --mannequin colour codes: head and hands grey, torso and arms blue, legs
# orange, feet dark. Hair takes the head colour. Far limbs still drop one step.
MANNEQUIN_MATERIALS: dict[str, tuple] = {
    "hair": tuple(rgb(c) for c in ("#f0f0f0", "#cfcfcf", "#a6a6a6", "#7c7c7c")),
    "skin": tuple(rgb(c) for c in ("#f0f0f0", "#cfcfcf", "#a6a6a6", "#7c7c7c")),
    "tunic": tuple(rgb(c) for c in ("#8cc0ff", "#5a8ee6", "#3c66b0", "#284478")),
    "pants": tuple(rgb(c) for c in ("#ffbc7a", "#ee9244", "#bc6a2e", "#824622")),
    "boot": tuple(rgb(c) for c in ("#90909e", "#6a6a78", "#4c4c5a", "#32323e")),
}
OUTLINE = rgb("#1e1628")
EYE = rgb("#1e1628")
BUCKLE = rgb("#f6cc60")
GUN_GLOW = rgb("#78e6ff")

FX = {
    "white": rgb("#ffffff"),
    "cyan": rgb("#b4f0ff"),
    "blue": rgb("#6eb4f0"),
    "dust": rgb("#e8dec8"),
    "dust_dark": rgb("#b8a88c"),
    "flash": rgb("#ffec8c"),
    "flash_hot": rgb("#fffbe0"),
    "flash_edge": rgb("#ffaa46"),
    "bubble": rgb("#c8f0ff"),
    "bubble_edge": rgb("#78bee6"),
    "ghost": rgb("#6ed2ff"),
    "ghost_dark": rgb("#3c96dc"),
    "spark": rgb("#fff4b0"),
}

# Light falls from the upper front (screen space, y down).
LIGHT = (0.55, -0.83)


# ---------------------------------------------------------------------------
# Head templates (side view faces right). Keys:
#   L/H/h/d hair hi/base/shadow/dark   K/S/s skin hi/base/shadow
#   E eye   B blush   . transparent
# The neck attaches at (attach_col, attach_row) in template pixels.
# ---------------------------------------------------------------------------

HEAD_TEMPLATES: dict[str, list[str]] = {
    "side": [
        "..hHHHL.",
        ".hHHHLLH",
        "hHHHHHHL",
        "hHHHHHHH",
        "dhHHhSSH",
        "dhhsSSES",
        "dhhsSSES",
        ".dhsSSBS",
        "..dsSSs.",
    ],
    "blink": [
        "..hHHHL.",
        ".hHHHLLH",
        "hHHHHHHL",
        "hHHHHHHH",
        "dhHHhSSH",
        "dhhsSSSS",
        "dhhsSSES",
        ".dhsSSBS",
        "..dsSSs.",
    ],
    "hurt": [
        "..hHHHL.",
        ".hHHHLLH",
        "hHHHHHHL",
        "hHHHHHHH",
        "dhHHhSSH",
        "dhhsSEES",
        "dhhsSSSS",
        ".dhsSSSE",
        "..dsSSs.",
    ],
    "effort": [
        "..hHHHL.",
        ".hHHHLLH",
        "hHHHHHHL",
        "hHHHHHHH",
        "dhHHhSSH",
        "dhhsSSES",
        "dhhsSSSS",
        ".dhsSSES",
        "..dsSSs.",
    ],
    "back": [
        "..hHHh..",
        ".hHHLHh.",
        "hHHLLHHh",
        "hHHHHHHh",
        "hHHHHHHh",
        "dhHHHHhd",
        "shhHHhhs",
        ".dhhhhd.",
        "..ssss..",
    ],
}
HEAD_ATTACH = {"side": (3.5, 8.6), "back": (4.0, 8.6)}
HEAD_KEYS = {
    "L": ("hair", 0), "H": ("hair", 1), "h": ("hair", 2), "d": ("hair", 3),
    "K": ("skin", 0), "S": ("skin", 1), "s": ("skin", 2),
}


def head_view(name: str) -> str:
    return "back" if name == "back" else "side"


def rotate_template(rows: list[str], quarter_turns: int) -> list[str]:
    """Rotate a template counter-clockwise (screen space) in 90 degree steps."""
    grid = [list(row) for row in rows]
    for _ in range(quarter_turns % 4):
        height, width = len(grid), len(grid[0])
        grid = [[grid[r][width - 1 - c] for r in range(height)] for c in range(width)]
    return ["".join(row) for row in grid]


# ---------------------------------------------------------------------------
# Skeleton
# ---------------------------------------------------------------------------
# Local coordinates: origin on the ground under the body centre, x forward
# (the frame faces right), y up. Limb angles are degrees measured from
# straight down, positive swinging forward: 0 down, 90 forward, 180 up.

THIGH = 5.4
SHIN = 5.2
TORSO = 7.0
UPPER_ARM = 4.0
FOREARM = 3.8
# Seen from behind, a reaching arm is not foreshortened by the shoulder turn,
# so the climbing view gets a little more reach to grip above the head.
BACK_UPPER_ARM = 4.6
BACK_FOREARM = 4.4
ANKLE_Y = 1.25
STAND_HIP_Y = 11.4


def ang_dir(theta: float) -> tuple[float, float]:
    t = math.radians(theta)
    return (math.sin(t), -math.cos(t))


def add(a, b, s: float = 1.0):
    return (a[0] + b[0] * s, a[1] + b[1] * s)


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def length(v) -> float:
    return math.hypot(v[0], v[1])


def lerp(a, b, t: float):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def angle_of(v) -> float:
    """Inverse of ang_dir: degrees from straight down, positive forward."""
    return math.degrees(math.atan2(v[0], -v[1]))


@dataclass
class Limb:
    mode: str  # "fk" or "ik"
    upper: float = 0.0
    lower: float = 0.0
    target: tuple[float, float] | None = None
    prefer: tuple[float, float] = (1.0, 0.0)
    toe: float | None = None
    hidden: bool = False


def fk(upper: float, lower: float, toe: float | None = None) -> Limb:
    return Limb("fk", upper=upper, lower=lower, toe=toe)


def ik(x: float, y: float, prefer=(1.0, 0.0), toe: float | None = None) -> Limb:
    return Limb("ik", target=(x, y), prefer=prefer, toe=toe)


def solve_limb(root, limb: Limb, a: float, b: float):
    if limb.mode == "fk":
        joint = add(root, ang_dir(limb.upper), a)
        end = add(joint, ang_dir(limb.lower), b)
        return joint, end
    target = limb.target
    delta = sub(target, root)
    dist0 = length(delta)
    if dist0 < 1e-6:
        delta, dist0 = (0.0, -1.0), 1.0
    ux, uy = delta[0] / dist0, delta[1] / dist0
    dist = min(max(dist0, abs(a - b) + 1e-3), a + b - 1e-3)
    cos_a = (a * a + dist * dist - b * b) / (2 * a * dist)
    ang = math.acos(max(-1.0, min(1.0, cos_a)))
    best = None
    for sign in (1, -1):
        ca, sa = math.cos(sign * ang), math.sin(sign * ang)
        direction = (ux * ca - uy * sa, ux * sa + uy * ca)
        joint = add(root, direction, a)
        mid = add(root, (ux, uy), dist * 0.5)
        score = (joint[0] - mid[0]) * limb.prefer[0] + (joint[1] - mid[1]) * limb.prefer[1]
        if best is None or score > best[0]:
            best = (score, joint)
    end = add(root, (ux, uy), dist)
    return best[1], end


@dataclass
class Pose:
    view: str = "side"
    hip: tuple[float, float] = (0.0, STAND_HIP_Y)
    lean: float = 2.0
    head: str = "side"
    head_offset: tuple[float, float] = (0.0, 0.0)
    head_rot: int = 0
    # side view: near/far; back view: right/left of the screen
    arm_n: Limb = field(default_factory=lambda: fk(-8, 10))
    arm_f: Limb = field(default_factory=lambda: fk(10, 25))
    leg_n: Limb = field(default_factory=lambda: ik(1.6, ANKLE_Y))
    leg_f: Limb = field(default_factory=lambda: ik(-1.4, ANKLE_Y))
    scarf_angle: float = 70.0
    scarf_wave: float = 0.6
    scarf_phase: float = 0.0
    scarf_len: int = 5
    props: list = field(default_factory=list)
    fx: list = field(default_factory=list)
    ghosts: list = field(default_factory=list)
    rot: int = 0
    rot_pivot: tuple[float, float] = (0.0, 8.0)
    shift: tuple[int, int] = (0, 0)
    # After rotating, move the figure so its lowest pixel rests on the ground.
    snap_to_ground: bool = False
    # Overhead reaches draw the near arm behind the head so the face shows.
    near_arm_behind_head: bool = False
    pack: bool = True


# ---------------------------------------------------------------------------
# Raster helpers
# ---------------------------------------------------------------------------


class Frame:
    """One animation frame: a figure layer (with part tags) plus effects."""

    def __init__(self, width: int, height: int):
        self.w = width
        self.h = height
        self.cx = width / 2.0
        # Body soles rest on this screen row boundary; the outline row sits on
        # it and BOTTOM_MARGIN rows stay empty below.
        self.ground = height - BOTTOM_MARGIN - 1
        self.fig: dict[tuple[int, int], tuple[tuple, str, float]] = {}
        self.fx: dict[tuple[int, int], tuple] = {}
        self.behind: dict[tuple[int, int], tuple] = {}

    def screen(self, p) -> tuple[float, float]:
        return (self.cx + p[0], self.ground - p[1])

    def put(self, x: int, y: int, color, part: str, z: float) -> None:
        cur = self.fig.get((x, y))
        if cur is None or z >= cur[2]:
            self.fig[(x, y)] = (color, part, z)

    def capsule(self, p0, p1, r: float, material: str, part: str, z: float,
                tone: int = 0, highlight: bool = True) -> None:
        s0, s1 = self.screen(p0), self.screen(p1)
        pal = MATERIALS[material]
        x0 = int(math.floor(min(s0[0], s1[0]) - r - 1))
        x1 = int(math.ceil(max(s0[0], s1[0]) + r + 1))
        y0 = int(math.floor(min(s0[1], s1[1]) - r - 1))
        y1 = int(math.ceil(max(s0[1], s1[1]) + r + 1))
        dx, dy = s1[0] - s0[0], s1[1] - s0[1]
        seg2 = dx * dx + dy * dy
        for py in range(y0, y1 + 1):
            for px in range(x0, x1 + 1):
                qx, qy = px + 0.5, py + 0.5
                t = 0.0 if seg2 < 1e-9 else max(0.0, min(1.0, ((qx - s0[0]) * dx + (qy - s0[1]) * dy) / seg2))
                cx, cy = s0[0] + dx * t, s0[1] + dy * t
                nx, ny = qx - cx, qy - cy
                if nx * nx + ny * ny > r * r + 0.02:
                    continue
                shade = (nx * LIGHT[0] + ny * LIGHT[1]) / max(r, 0.5)
                if shade > 0.45 and highlight:
                    idx = 0
                elif shade < -0.3:
                    idx = 2
                else:
                    idx = 1
                idx = min(3, idx + tone)
                self.put(px, py, pal[idx], part, z)

    def polygon(self, points, material: str, part: str, z: float, tone: int = 0) -> None:
        pts = [self.screen(p) for p in points]
        pal = MATERIALS[material]
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        mask = set()
        for py in range(int(math.floor(min(ys))), int(math.ceil(max(ys))) + 1):
            for px in range(int(math.floor(min(xs))), int(math.ceil(max(xs))) + 1):
                if point_in_polygon(px + 0.5, py + 0.5, pts):
                    mask.add((px, py))
        for (px, py) in mask:
            idx = 1
            if (px - 1, py + 1) not in mask or (px, py + 1) not in mask:
                idx = 2
            elif (px + 1, py - 1) not in mask and (px, py - 1) not in mask:
                idx = 0
            self.put(px, py, pal[min(3, idx + tone)], part, z)

    def template(self, rows: list[str], anchor_screen, attach, part: str, z: float) -> None:
        ox = math.floor(anchor_screen[0] - attach[0] + 0.5)
        oy = math.floor(anchor_screen[1] - attach[1] + 0.5)
        for r, row in enumerate(rows):
            for c, ch in enumerate(row):
                if ch == ".":
                    continue
                if ch == "E":
                    color = EYE
                elif ch == "B":
                    color = MATERIALS["skin"][1] if MANNEQUIN else rgb("#e88878")
                else:
                    material, idx = HEAD_KEYS[ch]
                    color = MATERIALS[material][idx]
                self.put(ox + c, oy + r, color, part, z)

    # -- post processing -------------------------------------------------

    def separate(self, targets: set[str]) -> None:
        """Darken the edge of a lower part where a higher part overlaps it."""
        updates = {}
        for (x, y), (color, part, z) in self.fig.items():
            if part not in targets:
                continue
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                other = self.fig.get((nx, ny))
                if other is None or other[1] == part or other[2] <= z:
                    continue
                if other[1] in NO_SEPARATION.get(part, ()):
                    continue
                material = PART_MATERIAL.get(part)
                if material:
                    updates[(x, y)] = (MATERIALS[material][3], part, z)
                break
        self.fig.update(updates)

    def rotate(self, quarter_turns: int, pivot_local) -> None:
        if quarter_turns % 4 == 0:
            return
        px, py = self.screen(pivot_local)
        out = {}
        for (x, y), value in self.fig.items():
            # rotate pixel centres counter-clockwise on screen
            cx, cy = x + 0.5 - px, y + 0.5 - py
            for _ in range(quarter_turns % 4):
                cx, cy = cy, -cx
            out[(int(math.floor(cx + px)), int(math.floor(cy + py)))] = value
        self.fig = out

    def translate(self, dx: int, dy: int) -> None:
        if dx or dy:
            self.fig = {(x + dx, y - dy): v for (x, y), v in self.fig.items()}

    def outline(self) -> dict[tuple[int, int], tuple]:
        ring = {}
        for (x, y) in self.fig:
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if (nx, ny) not in self.fig:
                    ring[(nx, ny)] = OUTLINE
        return ring

    def ghost(self, dx: int, dy: int, phase: int, color_key: str = "ghost") -> None:
        """Sparse diagonal-streaked after-image of the figure, drawn behind it."""
        for (x, y) in list(self.fig):
            gx, gy = x - dx, y + dy
            if (gx + gy + phase) % 3 == 0:
                self.behind[(gx, gy)] = FX[color_key] if (gx - gy) % 2 else FX["ghost_dark"]

    def to_image(self) -> Image.Image:
        image = Image.new("RGBA", (self.w, self.h), (0, 0, 0, 0))
        pixels = image.load()

        def plot(x, y, color):
            if 0 <= x < self.w and 0 <= y < self.h:
                pixels[x, y] = color

        ring = self.outline()
        for (x, y), color in self.behind.items():
            if (x, y) not in self.fig and (x, y) not in ring:
                plot(x, y, color)
        for (x, y), color in ring.items():
            plot(x, y, color)
        for (x, y), (color, _part, _z) in self.fig.items():
            plot(x, y, color)
        for (x, y), color in self.fx.items():
            plot(x, y, color)
        return image


def point_in_polygon(x: float, y: float, pts) -> bool:
    inside = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > y) != (yj > y):
            cross = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < cross:
                inside = not inside
        j = i
    return inside


PART_MATERIAL = {
    "torso": "tunic", "pack": "pack", "leg_f": "pants", "leg_n": "pants",
    "head": "hair", "scarf": "scarf", "arm_f": "tunic", "boot_f": "boot",
}
SEPARATION_TARGETS = {"torso", "pack", "leg_f", "leg_n", "boot_f"}
NO_SEPARATION = {
    "torso": ("belt", "hem", "knot"),
    "leg_n": ("boot_n",),
    "leg_f": ("boot_f",),
    "boot_f": ("leg_f",),
}


# ---------------------------------------------------------------------------
# Figure renderer
# ---------------------------------------------------------------------------


def draw_pose(frame: Frame, pose: Pose) -> None:
    if pose.view == "back":
        draw_back(frame, pose)
    else:
        draw_side(frame, pose)
    frame.separate(SEPARATION_TARGETS)
    frame.rotate(pose.rot, pose.rot_pivot)
    frame.translate(*pose.shift)
    if pose.snap_to_ground and frame.fig:
        lowest = max(y for (_x, y) in frame.fig)
        frame.translate(0, lowest - (frame.ground - 1))
    for ghost in pose.ghosts:
        frame.ghost(*ghost)
    for effect in pose.fx:
        draw_fx(frame, effect)


def torso_points(pose: Pose):
    hip = pose.hip
    up = ang_dir(180 - pose.lean)  # lean forward tilts the torso toward +x
    neck = add(hip, up, TORSO)
    forward = (-up[1], up[0])  # perpendicular, pointing to the front
    if forward[0] < 0:
        forward = (-forward[0], -forward[1])
    return hip, neck, up, forward


def draw_leg(frame: Frame, hip, limb: Limb, far: bool, z: float, back_view: bool = False) -> None:
    if limb.hidden:
        return
    knee, ankle = solve_limb(hip, limb, THIGH, SHIN)
    tone = 1 if far else 0
    part = "leg_f" if far else "leg_n"
    boot_part = "boot_f" if far else "boot_n"
    frame.capsule(hip, knee, 1.45, "pants", part, z, tone)
    boot_start = lerp(knee, ankle, 0.42)
    frame.capsule(knee, boot_start, 1.35, "pants", part, z, tone)
    frame.capsule(boot_start, ankle, 1.45, "boot", boot_part, z + 0.1, tone)
    if back_view:
        toe_dir = ang_dir(limb.toe if limb.toe is not None else 0.0)
        frame.capsule(ankle, add(ankle, toe_dir, 0.6), 1.35, "boot", boot_part, z + 0.1, tone + 1)
        return
    shin_angle = angle_of(sub(ankle, knee))
    toe_angle = limb.toe if limb.toe is not None else max(40.0, min(125.0, shin_angle + 90.0))
    frame.capsule(ankle, add(ankle, ang_dir(toe_angle), 2.1), 1.2, "boot", boot_part, z + 0.1, tone)


def draw_arm(frame: Frame, shoulder, limb: Limb, far: bool, z: float):
    if limb.hidden:
        return None
    elbow, hand = solve_limb(shoulder, limb, UPPER_ARM, FOREARM)
    tone = 1 if far else 0
    part = "arm_f" if far else "arm_n"
    frame.capsule(shoulder, elbow, 1.2, "tunic", part, z, tone)
    frame.capsule(elbow, hand, 1.0, "skin", part, z + 0.05, tone)
    frame.capsule(hand, hand, 1.3, "skin", part, z + 0.1, tone)
    return hand


def scarf_chain(origin, angle: float, wave: float, phase: float, count: int, step: float = 1.6, sideways: float = 0.0):
    """Points of a scarf tail trailing behind (-x) the neck."""
    pts = [origin]
    direction = math.radians(angle)
    for i in range(1, count + 1):
        base = (-math.cos(direction) * step * i, -math.sin(direction) * step * i)
        bend = wave * math.sin(phase * 2 * math.pi + i * 1.1) * min(1.0, i / 2.0)
        normal = (math.sin(direction), -math.cos(direction))
        pts.append((origin[0] + base[0] + normal[0] * bend + sideways * i,
                    origin[1] + base[1] + normal[1] * bend))
    return pts


def draw_side(frame: Frame, pose: Pose) -> None:
    hip, neck, up, forward = torso_points(pose)
    shoulder = add(neck, up, -1.2)
    shoulder_n = add(shoulder, forward, 0.3)
    shoulder_f = add(shoulder, forward, -0.6)
    hip_n = add(hip, forward, 0.5)
    hip_f = add(hip, forward, -0.5)

    # far arm and far leg sit behind everything
    draw_arm(frame, shoulder_f, pose.arm_f, True, 10)
    draw_leg(frame, hip_f, pose.leg_f, True, 20)

    # backpack on the back
    if pose.pack and not MANNEQUIN:
        back = (-forward[0], -forward[1])
        p0 = add(add(hip, up, TORSO * 0.42), back, 2.6)
        p1 = add(add(hip, up, TORSO * 0.82), back, 2.6)
        frame.capsule(p0, p1, 1.75, "pack", "pack", 25)
        frame.capsule(add(p1, up, 0.6), add(p1, up, 0.6), 1.2, "pack", "pack", 25.1, 1)

    # scarf tails stream behind the neck
    if not MANNEQUIN:
        tail_root = add(add(neck, up, -0.6), forward, -1.2)
        chain = scarf_chain(tail_root, pose.scarf_angle, pose.scarf_wave, pose.scarf_phase, pose.scarf_len)
        for i in range(len(chain) - 1):
            radius = 1.05 if i < len(chain) - 2 else 0.8
            frame.capsule(chain[i], chain[i + 1], radius, "scarf", "scarf", 27 + i * 0.01)

    draw_leg(frame, hip_n, pose.leg_n, False, 30)

    # torso, tunic hem and belt
    frame.capsule(hip, neck, 2.45, "tunic", "torso", 40)
    hem = [
        add(add(hip, forward, -2.6), up, 1.2),
        add(add(hip, forward, 2.5), up, 1.2),
        add(add(hip, forward, 2.9), up, -1.6),
        add(add(hip, forward, -3.4), up, -1.9),
    ]
    frame.polygon(hem, "tunic", "hem", 41)
    if not MANNEQUIN:
        belt_a = add(add(hip, up, 1.1), forward, -2.4)
        belt_b = add(add(hip, up, 1.1), forward, 2.4)
        frame.capsule(belt_a, belt_b, 0.55, "belt", "belt", 42, highlight=False)
        bx, by = frame.screen(add(add(hip, up, 1.1), forward, 2.0))
        frame.put(int(math.floor(bx)), int(math.floor(by)), BUCKLE, "belt", 42.5)

        # scarf knot around the neck
        frame.capsule(add(add(neck, up, -0.7), forward, -1.6), add(add(neck, up, -0.7), forward, 1.4), 1.25,
                      "scarf", "knot", 45)

    # head
    rows = HEAD_TEMPLATES[pose.head]
    attach = HEAD_ATTACH[head_view(pose.head)]
    if pose.head_rot:
        rows = rotate_template(rows, pose.head_rot)
        attach = rotate_attach(attach, HEAD_TEMPLATES[pose.head], pose.head_rot)
    anchor = frame.screen(add(neck, pose.head_offset))
    frame.template(rows, anchor, attach, "head", 50)

    for prop in pose.props:
        draw_prop(frame, prop, pose)

    draw_arm(frame, shoulder_n, pose.arm_n, False, 48 if pose.near_arm_behind_head else 60)


def rotate_attach(attach, rows, quarter_turns: int):
    x, y = attach
    w, h = len(rows[0]), len(rows)
    for _ in range(quarter_turns % 4):
        x, y = y, w - x
        w, h = h, w
    return (x, y)


def draw_back(frame: Frame, pose: Pose) -> None:
    hip = pose.hip
    neck = add(hip, (0.0, 1.0), TORSO)
    shoulder_y = neck[1] - 1.0
    # arms reach to the ladder in front of the body: behind torso and head
    for limb, side in ((pose.arm_n, 1), (pose.arm_f, -1)):
        if limb.hidden:
            continue
        shoulder = (hip[0] + side * 2.6, shoulder_y)
        elbow, hand = solve_limb(shoulder, limb, BACK_UPPER_ARM, BACK_FOREARM)
        part = "arm_n" if side > 0 else "arm_f"
        frame.capsule(shoulder, elbow, 1.2, "tunic", part, 15 + side * 0.1)
        frame.capsule(elbow, hand, 1.0, "skin", part, 15.05 + side * 0.1)
        frame.capsule(hand, hand, 1.35, "skin", part, 15.1 + side * 0.1)
    for limb, side in ((pose.leg_n, 1), (pose.leg_f, -1)):
        draw_leg(frame, (hip[0] + side * 1.5, hip[1]), limb, side < 0, 20 + side * 0.1, back_view=True)
    frame.capsule(hip, neck, 3.1, "tunic", "torso", 30)
    hem = [(hip[0] - 3.3, hip[1] + 1.2), (hip[0] + 3.3, hip[1] + 1.2),
           (hip[0] + 3.9, hip[1] - 1.8), (hip[0] - 3.9, hip[1] - 1.8)]
    frame.polygon(hem, "tunic", "hem", 31)
    if not MANNEQUIN:
        frame.capsule((hip[0] - 3.0, hip[1] + 1.1), (hip[0] + 3.0, hip[1] + 1.1), 0.55, "belt", "belt", 32,
                      highlight=False)
    if pose.pack and not MANNEQUIN:
        frame.capsule((hip[0], hip[1] + 3.2), (hip[0], hip[1] + 5.6), 2.4, "pack", "pack", 35)
        frame.capsule((hip[0] - 1.6, hip[1] + 6.0), (hip[0] + 1.6, hip[1] + 6.0), 0.6, "pack", "pack", 35.2, 1)
        fx_, fy_ = frame.screen((hip[0] + 0.2, hip[1] + 4.6))
        frame.put(int(math.floor(fx_)), int(math.floor(fy_)), BUCKLE, "pack", 35.3)
    # scarf hangs down the back over the pack
    if not MANNEQUIN:
        root = (neck[0] + 0.4, neck[1] - 0.8)
        pts = [root]
        for i in range(1, pose.scarf_len + 1):
            sway = pose.scarf_wave * math.sin(pose.scarf_phase * 2 * math.pi + i * 0.9) * min(1.0, i / 2.5)
            pts.append((root[0] + 0.5 * i * 0.3 + sway, root[1] - 1.45 * i))
        for i in range(len(pts) - 1):
            frame.capsule(pts[i], pts[i + 1], 0.95 if i < len(pts) - 2 else 0.75, "scarf", "scarf", 37 + i * 0.01)
        frame.capsule((neck[0] - 2.4, neck[1] - 0.8), (neck[0] + 2.4, neck[1] - 0.8), 1.2, "scarf", "knot", 38)
    rows = HEAD_TEMPLATES[pose.head]
    frame.template(rows, frame.screen(add(neck, pose.head_offset)), HEAD_ATTACH["back"], "head", 40)


# ---------------------------------------------------------------------------
# Props
# ---------------------------------------------------------------------------


def unit_deg(deg: float) -> tuple[float, float]:
    """Math angle (0 = forward, 90 = up) to a local direction."""
    r = math.radians(deg)
    return (math.cos(r), math.sin(r))


def hand_of(pose: Pose, which: str):
    """Recompute a hand position without drawing it."""
    hip, neck, up, forward = torso_points(pose)
    shoulder = add(neck, up, -1.2)
    if which == "near":
        root, limb = add(shoulder, forward, 0.3), pose.arm_n
    else:
        root, limb = add(shoulder, forward, -0.6), pose.arm_f
    return solve_limb(root, limb, UPPER_ARM, FOREARM)[1]


def draw_prop(frame: Frame, prop: dict, pose: Pose) -> None:
    kind = prop["kind"]
    hand = hand_of(pose, prop.get("hand", "near"))
    if kind == "sword":
        d = unit_deg(prop["angle"])
        n = (-d[1], d[0])
        z = prop.get("z", 55)
        frame.capsule(add(hand, d, -1.4), add(hand, d, 0.6), 0.6, "grip", "sword", z, highlight=False)
        guard_c = add(hand, d, 1.2)
        frame.capsule(add(guard_c, n, -1.6), add(guard_c, n, 1.6), 0.6, "guard", "sword", z + 0.1)
        blade_len = prop.get("length", 10.5)
        frame.capsule(add(hand, d, 1.9), add(hand, d, 1.9 + blade_len), 0.75, "blade", "sword", z + 0.05)
    elif kind == "gun":
        d = unit_deg(prop.get("angle", 0.0))
        n = (-d[1], d[0])
        z = prop.get("z", 55)
        frame.capsule(add(hand, n, -0.4), add(add(hand, n, -1.8), d, -0.6), 0.65, "gun", "gun", z, 1)
        body0 = add(add(hand, d, -1.2), n, 0.7)
        body1 = add(add(hand, d, 3.6), n, 0.7)
        frame.capsule(body0, body1, 0.95, "gun", "gun", z + 0.1)
        tip = add(add(hand, d, 4.6), n, 0.7)
        sx, sy = frame.screen(tip)
        frame.put(int(math.floor(sx)), int(math.floor(sy)), GUN_GLOW, "gun", z + 0.2)
        ax, ay = frame.screen(add(add(hand, d, 0.8), n, 1.4))
        frame.put(int(math.floor(ax)), int(math.floor(ay)), MATERIALS["guard"][1], "gun", z + 0.2)


def muzzle(pose: Pose, hand: str = "near", angle: float = 0.0):
    h = hand_of(pose, hand)
    d = unit_deg(angle)
    n = (-d[1], d[0])
    return add(add(h, d, 5.8), n, 0.7)


# ---------------------------------------------------------------------------
# Effects (no outline)
# ---------------------------------------------------------------------------


def fx_put(frame: Frame, x: float, y: float, color) -> None:
    frame.fx[(int(math.floor(x)), int(math.floor(y)))] = color


def draw_fx(frame: Frame, effect: tuple) -> None:
    kind = effect[0]
    if kind == "arc":
        # ("arc", centre, radius, start_deg, end_deg, thickness)
        _, centre, radius, start, end, thick = effect
        cx, cy = frame.screen(centre)
        lo, hi = min(start, end), max(start, end)
        for py in range(int(cy - radius - thick - 2), int(cy + radius + thick + 2)):
            for px in range(int(cx - radius - thick - 2), int(cx + radius + thick + 2)):
                dx, dy = px + 0.5 - cx, -(py + 0.5 - cy)
                dist = math.hypot(dx, dy)
                ang = math.degrees(math.atan2(dy, dx))
                while ang < lo:
                    ang += 360
                while ang > lo + 360:
                    ang -= 360
                if ang > hi:
                    continue
                u = (ang - start) / (end - start) if end != start else 1.0
                width = thick * (0.35 + 0.65 * u)
                if abs(dist - radius) > width / 2:
                    continue
                if u > 0.72:
                    color = FX["white"]
                elif u > 0.4:
                    color = FX["cyan"]
                elif (px + py) % 2 == 0:
                    color = FX["blue"]
                else:
                    continue
                if dist > radius + width / 2 - 0.9 and u > 0.4:
                    color = FX["white"]
                frame.fx[(px, py)] = color
    elif kind == "impact":
        # ("impact", point, size)
        _, point, size = effect
        cx, cy = frame.screen(point)
        fx_put(frame, cx, cy, FX["white"])
        for i in range(1, size + 1):
            color = FX["white"] if i < size else FX["flash"]
            for dx, dy in ((i, 0), (-i, 0), (0, i), (0, -i)):
                fx_put(frame, cx + dx, cy + dy, color)
        for i in range(1, max(1, size - 1)):
            for dx, dy in ((i, i), (-i, i), (i, -i), (-i, -i)):
                fx_put(frame, cx + dx, cy + dy, FX["flash"])
    elif kind == "flash":
        # ("flash", point, size) muzzle flash pointing forward
        _, point, size = effect
        cx, cy = frame.screen(point)
        for dx in range(0, size * 2 + 1):
            half = max(0, size - abs(dx - size) // 1 - (1 if dx > size else 0))
            for dy in range(-half, half + 1):
                color = FX["flash_hot"] if abs(dy) < half - 0 and dx < size else FX["flash"]
                if abs(dy) == half and half > 0:
                    color = FX["flash_edge"]
                fx_put(frame, cx + dx, cy + dy, color)
        fx_put(frame, cx + size * 2 + 1, cy, FX["flash_edge"])
    elif kind == "dust":
        # ("dust", point, radius)
        _, point, radius = effect
        cx, cy = frame.screen(point)
        for py in range(int(cy - radius - 1), int(cy + radius + 2)):
            for px in range(int(cx - radius - 1), int(cx + radius + 2)):
                d = math.hypot(px + 0.5 - cx, py + 0.5 - cy)
                if d <= radius:
                    color = FX["dust_dark"] if (py + 0.5 - cy) > radius * 0.35 else FX["dust"]
                    frame.fx[(px, py)] = color
    elif kind == "puff":
        # ("puff", point, radius) hollow dust ring, for dissipating dust
        _, point, radius = effect
        cx, cy = frame.screen(point)
        for py in range(int(cy - radius - 1), int(cy + radius + 2)):
            for px in range(int(cx - radius - 1), int(cx + radius + 2)):
                d = math.hypot(px + 0.5 - cx, py + 0.5 - cy)
                if radius - 0.9 <= d <= radius and (px + py) % 2 == 0:
                    frame.fx[(px, py)] = FX["dust"]
    elif kind == "line":
        # ("line", start, length, color_key, dither)
        _, start, run, color_key, dither = effect
        sx, sy = frame.screen(start)
        step = 1 if run >= 0 else -1
        for i in range(0, int(abs(run))):
            if dither and i % 2:
                continue
            fx_put(frame, sx + i * step, sy, FX[color_key])
    elif kind == "bubble":
        _, point, size = effect
        cx, cy = frame.screen(point)
        if size <= 1:
            fx_put(frame, cx, cy, FX["bubble"])
            return
        for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            fx_put(frame, cx + dx, cy + dy, FX["bubble_edge"])
        fx_put(frame, cx, cy, FX["bubble"])
        fx_put(frame, cx - 1, cy - 1, FX["white"])
    elif kind == "spark":
        _, point = effect
        cx, cy = frame.screen(point)
        fx_put(frame, cx, cy, FX["spark"])
        fx_put(frame, cx + 1, cy, FX["flash_edge"])
    elif kind == "streak":
        # ("streak", start, length) thrust streak with bright head
        _, start, run = effect
        sx, sy = frame.screen(start)
        for i in range(int(run)):
            color = FX["white"] if i > run - 4 else (FX["cyan"] if i > run * 0.4 else FX["blue"])
            if i < run * 0.4 and i % 2:
                continue
            fx_put(frame, sx + i, sy, color)
            if i > run * 0.5:
                fx_put(frame, sx + i, sy - 1, FX["cyan"])
                fx_put(frame, sx + i, sy + 1, FX["blue"] if i % 2 else FX["cyan"])
    else:
        raise ValueError(f"unknown effect {kind}")


# ---------------------------------------------------------------------------
# Animation helpers
# ---------------------------------------------------------------------------


def smooth(t: float) -> float:
    return t * t * (3 - 2 * t)


def cycle(count: int) -> list[float]:
    return [i / count for i in range(count)]


def gait_foot(phase: float, stride: float, lift: float, stance: float = 0.5, heel: float = 0.0):
    """Ankle position in a locomotion cycle. Phase 0 = foot planted forward."""
    phase %= 1.0
    if phase < stance:
        s = phase / stance
        return (stride - 2 * stride * s, ANKLE_Y), True
    s = (phase - stance) / (1 - stance)
    x = -stride + 2 * stride * smooth(s)
    # a heel kick lifts the foot up behind the body early in the swing
    kick = heel * math.sin(math.pi * min(1.0, s * 1.6)) * (1 - s)
    y = ANKLE_Y + lift * math.sin(math.pi * s) + kick
    return (x - kick * 0.8, y), False


def locomotion(phase: float, stride: float, lift: float, hip_y: float, bob: float, lean: float,
               arm_swing: float, elbow: float, stance: float = 0.5, heel: float = 0.0,
               scarf_angle: float = 40.0, scarf_wave: float = 0.8, foot_offset: float = 0.0) -> Pose:
    near, near_down = gait_foot(phase, stride, lift, stance, heel)
    far, far_down = gait_foot(phase + 0.5, stride, lift, stance, heel)
    swing = math.cos(2 * math.pi * phase)
    return Pose(
        # lowest at contact, highest while the legs pass each other
        hip=(0.0, hip_y - bob * abs(swing)),
        lean=lean,
        arm_n=fk(-arm_swing * swing, -arm_swing * swing + elbow + max(0.0, arm_swing * swing) * 0.6),
        arm_f=fk(arm_swing * swing, arm_swing * swing + elbow + max(0.0, -arm_swing * swing) * 0.6),
        leg_n=ik(near[0] + foot_offset, near[1], toe=foot_toe(near, near_down)),
        leg_f=ik(far[0] + foot_offset, far[1], toe=foot_toe(far, far_down)),
        scarf_angle=scarf_angle,
        scarf_wave=scarf_wave,
        scarf_phase=phase * 2,
    )


def foot_toe(ankle, down: bool) -> float | None:
    """Flat while the foot is near the ground, free (pointing down) once lifted."""
    return 90.0 if down or ankle[1] < ANKLE_Y + 1.6 else None


def planted(x: float, prefer=(1.0, 0.0)) -> Limb:
    return ik(x, ANKLE_Y, prefer=prefer, toe=90)


def with_overrides(pose: Pose, overrides: dict) -> Pose:
    for key, value in overrides.items():
        setattr(pose, key, value)
    return pose


def guard_stance(**overrides) -> Pose:
    pose = Pose(
        hip=(0.0, 10.7),
        lean=8.0,
        leg_n=planted(2.8),
        leg_f=planted(-2.6),
        arm_n=ik(3.8, 17.6, prefer=(0.0, -1.0)),
        arm_f=ik(2.6, 16.8, prefer=(0.0, -1.0)),
        scarf_angle=62,
    )
    return with_overrides(pose, overrides)


def tuck_pose(**overrides) -> Pose:
    """Knees-to-chest ball used by the roll and the air spin."""
    pose = Pose(
        hip=(0.0, 9.0),
        lean=55.0,
        head_offset=(0.6, -1.4),
        leg_n=fk(120, 10, toe=100),
        leg_f=fk(105, -5, toe=90),
        arm_n=fk(95, 20),
        arm_f=fk(80, 10),
        scarf_angle=20,
        scarf_len=4,
    )
    return with_overrides(pose, overrides)


# ---------------------------------------------------------------------------
# Animations (every frame faces right; the engine mirrors for left)
# ---------------------------------------------------------------------------


def anim_idle() -> list[Pose]:
    poses = []
    for i, t in enumerate(cycle(8)):
        breath = 1.0 if i in (3, 4, 5) else 0.0
        sway = math.sin(2 * math.pi * t)
        poses.append(Pose(
            hip=(0.0, STAND_HIP_Y - breath * 0.9),
            lean=2.0 + breath,
            head="blink" if i == 6 else "side",
            arm_n=fk(-6 - sway * 2, 14 - sway * 3),
            arm_f=fk(8 + sway * 2, 26 + sway * 3),
            leg_n=planted(1.8),
            leg_f=planted(-1.6),
            scarf_angle=72,
            scarf_wave=0.7,
            scarf_phase=t,
        ))
    return poses


def anim_walk() -> list[Pose]:
    return [locomotion(t, 3.4, 1.8, STAND_HIP_Y - 0.1, 0.7, 5.0, 22.0, 16.0,
                       scarf_angle=48, scarf_wave=0.8) for t in cycle(8)]


def anim_run() -> list[Pose]:
    return [locomotion(t, 5.2, 3.2, STAND_HIP_Y - 0.6, 1.0, 14.0, 48.0, 80.0, stance=0.42,
                       heel=2.6, scarf_angle=12, scarf_wave=1.0) for t in cycle(8)]


def anim_jump() -> list[Pose]:
    """crouch, launch, rise (held while rising), then three falling frames."""
    crouch = Pose(hip=(0.0, 8.6), lean=14, arm_n=fk(-50, -25), arm_f=fk(-35, -10),
                  leg_n=planted(2.4), leg_f=planted(-1.8), scarf_angle=62, head="effort")
    launch = Pose(hip=(0.0, 13.2), lean=6, arm_n=fk(118, 138), arm_f=fk(204, 214),
                  leg_n=fk(-6, -14, toe=40), leg_f=fk(-16, -28, toe=35), scarf_angle=82, scarf_wave=0.4)
    rise = Pose(hip=(0.0, 12.4), lean=8, arm_n=fk(104, 128), arm_f=fk(-34, -8),
                leg_n=fk(58, -6, toe=80), leg_f=fk(10, -30, toe=50), scarf_angle=80, scarf_wave=0.5,
                scarf_phase=0.3)
    falls = []
    for i, (an, af, ln, lf) in enumerate((
            ((108, 124), (206, 220), (24, 4), (-8, -24)),
            ((114, 132), (198, 212), (28, 2), (-12, -28)),
            ((102, 118), (212, 226), (20, 8), (-6, -20)))):
        falls.append(Pose(hip=(0.0, 12.4), lean=4, arm_n=fk(*an), arm_f=fk(*af),
                          leg_n=fk(ln[0], ln[1], toe=72), leg_f=fk(lf[0], lf[1], toe=55),
                          scarf_angle=-48, scarf_wave=1.0, scarf_phase=i / 3))
    return [crouch, launch, rise] + falls


def anim_land() -> list[Pose]:
    poses = []
    steps = ((7.8, 18, (40, 70), (30, 60), -10), (8.8, 14, (25, 55), (20, 50), 30),
             (10.0, 8, (6, 32), (12, 36), 55), (10.9, 4, (-2, 20), (8, 28), 68),
             (STAND_HIP_Y, 2, (-6, 14), (8, 26), 72))
    for i, (hip_y, lean, an, af, scarf) in enumerate(steps):
        fx = []
        if i == 0:
            fx = [("dust", (5.0, 1.2), 1.4), ("dust", (-5.0, 1.2), 1.4)]
        elif i == 1:
            fx = [("dust", (6.8, 1.6), 1.8), ("dust", (-6.8, 1.6), 1.8)]
        elif i == 2:
            fx = [("puff", (8.4, 2.4), 2.2), ("puff", (-8.4, 2.4), 2.2)]
        poses.append(Pose(hip=(0.0, hip_y), lean=lean, arm_n=fk(*an), arm_f=fk(*af),
                          leg_n=planted(2.4 if i < 2 else 1.8), leg_f=planted(-2.0 if i < 2 else -1.6),
                          scarf_angle=scarf, fx=fx, head="effort" if i == 0 else "side"))
    return poses


def anim_dash() -> list[Pose]:
    poses = [Pose(hip=(0.0, 10.4), lean=22, arm_n=fk(-42, -12), arm_f=fk(-26, 0),
                  leg_n=planted(2.6), leg_f=planted(-2.4), scarf_angle=34, head="effort")]
    for i in range(4):
        pose = Pose(hip=(1.0, 10.8), lean=38, arm_n=fk(-72, -52), arm_f=fk(-58, -40),
                    leg_n=fk(62, 6, toe=95), leg_f=fk(-46, -62, toe=20),
                    scarf_angle=2, scarf_wave=0.6, scarf_phase=i / 4, head="effort")
        pose.ghosts = [(7, 0, i % 2)] if i < 3 else [(5, 0, i % 2)]
        lines = [(-8 - 2 * (i % 2), 6.0, -9), (-10 + (i % 2), 13.0, -11), (-7, 19.0, -7)]
        pose.fx = [("line", (x, y), run, "white", True) for x, y, run in lines]
        poses.append(pose)
    poses.append(Pose(hip=(0.6, 10.6), lean=16, arm_n=fk(30, 60), arm_f=fk(-20, 10),
                      leg_n=planted(2.4), leg_f=planted(-2.2), scarf_angle=20, scarf_wave=1.0))
    return poses


def anim_roll() -> list[Pose]:
    pivot = (0.8, 8.6)
    poses = [Pose(hip=(0.0, 9.4), lean=42, arm_n=fk(70, 92), arm_f=fk(58, 80),
                  leg_n=planted(2.4), leg_f=planted(-2.2), scarf_angle=30, head="effort")]
    for i, rot in enumerate((0, 3, 2, 1)):
        poses.append(tuck_pose(rot=rot, rot_pivot=pivot, scarf_phase=i / 4, snap_to_ground=True,
                               fx=[("dust", (-5.0 - i, 1.4), 1.2)] if i in (0, 1) else []))
    poses.append(Pose(hip=(0.4, 8.4), lean=30, arm_n=fk(52, 80), arm_f=fk(40, 70),
                      leg_n=planted(2.6), leg_f=planted(-2.0), scarf_angle=24))
    poses.append(Pose(hip=(0.2, 10.2), lean=12, arm_n=fk(18, 40), arm_f=fk(-10, 18),
                      leg_n=planted(2.0), leg_f=planted(-1.8), scarf_angle=48))
    return poses


def anim_slide() -> list[Pose]:
    poses = []
    for i in range(6):
        k = i % 3
        poses.append(Pose(
            hip=(1.0, 4.6), lean=-52,
            arm_n=ik(-5.6, 2.4, prefer=(0.0, 1.0)),
            arm_f=fk(118, 150),
            leg_n=fk(78, 86, toe=150),
            leg_f=ik(4.6, 2.8, prefer=(0.2, 1.0), toe=100),
            scarf_angle=-6, scarf_wave=0.9, scarf_phase=i / 6,
            head="effort",
            fx=[("dust", (12.6 + k * 0.8, 1.4), 1.3 + 0.2 * k), ("puff", (9.8 + k, 3.2 + k * 0.6), 1.6),
                ("dust", (-2.0 - k, 0.8), 0.9)],
        ))
    return poses


def anim_crouch_idle() -> list[Pose]:
    poses = []
    for i in range(6):
        breath = 0.5 if i in (2, 3, 4) else 0.0
        poses.append(Pose(hip=(0.0, 6.8 - breath), lean=32 + breath * 2,
                          leg_n=planted(2.6), leg_f=planted(-2.0),
                          arm_n=ik(4.8, 7.6 - breath, prefer=(0.0, -1.0)), arm_f=fk(36, 70),
                          scarf_angle=74, scarf_wave=0.5, scarf_phase=i / 6))
    return poses


def anim_crouch_walk() -> list[Pose]:
    return [locomotion(t, 2.8, 1.2, 6.9, 0.4, 32.0, 14.0, 40.0, scarf_angle=56, scarf_wave=0.7)
            for t in cycle(8)]


WALL_X = -6.6  # the wall the slide pose leans against (behind the body)


def anim_wall_slide() -> list[Pose]:
    poses = []
    for i, dangle in enumerate((12, 17, 8)):
        poses.append(Pose(
            hip=(-1.4, 12.8), lean=-5,
            arm_n=ik(WALL_X + 0.2, 19.0, prefer=(0.0, 1.0)),
            arm_f=fk(34, 66),
            leg_f=ik(WALL_X + 1.2, 5.6, prefer=(1.0, 0.2), toe=150),
            leg_n=fk(dangle, dangle - 10, toe=70),
            scarf_angle=-56, scarf_wave=1.0, scarf_phase=i / 3,
            fx=[("spark", (WALL_X - 0.4, 20.5 + i)), ("spark", (WALL_X + 0.3, 6.8 + i * 1.5)),
                ("bubble", (WALL_X + 0.4, 23.5 + i * 1.2), 1)],
        ))
    return poses


def anim_wall_land() -> list[Pose]:
    poses = []
    for i, (hip_y, lean, hand_y) in enumerate(((8.0, 12, 13.0), (9.0, 10, 13.6), (10.2, 5, 13.2),
                                               (11.0, 3, 12.0))):
        fx = []
        if i == 0:
            fx = [("dust", (-4.2, 1.2), 1.4), ("dust", (4.6, 1.2), 1.3)]
        elif i == 1:
            fx = [("dust", (-5.6, 1.6), 1.6), ("puff", (6.6, 2.0), 2.0)]
        poses.append(Pose(
            hip=(-0.8, hip_y), lean=lean,
            arm_n=ik(WALL_X + 0.4, hand_y, prefer=(0.0, 1.0)) if i < 3 else fk(-14, 6),
            arm_f=fk(42 - i * 10, 72 - i * 12),
            leg_n=planted(2.2), leg_f=planted(-2.6),
            scarf_angle=40 + i * 10, fx=fx, head="effort" if i == 0 else "side",
        ))
    return poses


def anim_hurt() -> list[Pose]:
    return [
        Pose(hip=(-0.6, 11.0), lean=-16, head="hurt", head_offset=(-0.4, 0.0),
             arm_n=fk(72, 112), arm_f=fk(96, 132), leg_n=planted(2.4), leg_f=planted(-2.0),
             scarf_angle=18, scarf_wave=1.0, fx=[("impact", (4.0, 17.4), 2)]),
        Pose(hip=(-1.2, 10.6), lean=-22, head="hurt", head_offset=(-0.6, 0.0),
             arm_n=fk(60, 100), arm_f=fk(84, 120), leg_n=ik(3.2, 2.8, toe=70), leg_f=planted(-2.2),
             scarf_angle=8, scarf_wave=1.0, scarf_phase=0.5, fx=[("puff", (4.4, 17.6), 2.4)]),
        Pose(hip=(-0.6, 10.8), lean=-8, head="hurt", arm_n=fk(26, 56), arm_f=fk(32, 62),
             leg_n=planted(2.2), leg_f=planted(-2.0), scarf_angle=40),
        Pose(hip=(-0.2, 11.2), lean=0, arm_n=fk(-4, 18), arm_f=fk(10, 28),
             leg_n=planted(2.0), leg_f=planted(-1.8), scarf_angle=64),
    ]


def anim_death() -> list[Pose]:
    kneel = fk(22, -89, toe=-95)
    poses = [
        Pose(hip=(-0.6, 11.0), lean=-16, head="hurt", arm_n=fk(72, 112), arm_f=fk(96, 132),
             leg_n=planted(2.4), leg_f=planted(-2.0), scarf_angle=18, fx=[("impact", (4.0, 17.4), 2)]),
        Pose(hip=(-1.4, 10.6), lean=-20, head="hurt", arm_n=fk(58, 96), arm_f=fk(78, 116),
             leg_n=ik(3.0, 2.6, toe=70), leg_f=planted(-2.4), scarf_angle=10),
        Pose(hip=(-0.8, 8.6), lean=-4, head="hurt", head_offset=(0.4, -0.6),
             arm_n=fk(6, 12), arm_f=fk(12, 18), leg_n=planted(2.4), leg_f=planted(-2.0), scarf_angle=60),
        Pose(hip=(-0.4, 6.6), lean=4, head="hurt", head_offset=(0.5, -1.0),
             arm_n=fk(2, 6), arm_f=fk(8, 12), leg_n=kneel, leg_f=planted(2.4, prefer=(1.0, 1.0)),
             scarf_angle=76),
        Pose(hip=(-0.4, 6.2), lean=14, head="hurt", head_offset=(0.9, -1.6),
             arm_n=fk(10, 10), arm_f=fk(14, 16), leg_n=kneel, leg_f=planted(2.4, prefer=(1.0, 1.0)),
             scarf_angle=80),
        Pose(hip=(-1.6, 4.8), lean=-40, head="hurt", arm_n=fk(150, 172), arm_f=fk(128, 150),
             leg_n=ik(2.6, 2.2, prefer=(0.2, 1.0), toe=90), leg_f=ik(1.8, ANKLE_Y, prefer=(0.2, 1.0), toe=90),
             scarf_angle=20),
        Pose(hip=(-2.4, 3.8), lean=-70, head="hurt", head_rot=1,
             arm_n=ik(-1.6, 7.4, prefer=(0.0, 1.0)), arm_f=fk(-60, -80),
             leg_n=ik(4.2, 3.4, prefer=(0.3, 1.0), toe=120), leg_f=ik(3.4, ANKLE_Y, prefer=(0.3, 1.0)),
             scarf_angle=-20),
    ]
    lying = dict(lean=-90, head="hurt", head_rot=1,
                 arm_n=ik(-2.2, 4.6, prefer=(0.0, 1.0)), arm_f=fk(-92, -94),
                 leg_n=fk(84, 92, toe=170), leg_f=ik(7.0, 2.0, prefer=(0.0, 1.0), toe=150),
                 scarf_angle=-2, scarf_wave=0.3)
    poses.append(Pose(hip=(-2.0, 4.6), **lying))
    poses.append(Pose(hip=(-2.0, 3.9), **lying))
    poses.append(Pose(hip=(-2.0, 3.9), **lying))
    return poses


LEDGE_X = 6.4  # hands grip the ledge top at the wall face in front


def hang_pose(t: float) -> Pose:
    swing = math.sin(2 * math.pi * t)
    # Arms reach forward-up past the front of the face to the ledge; the head
    # sits back so the eye stays visible behind the near arm.
    return Pose(
        hip=(-1.2, 14.8), lean=6 + swing,
        head_offset=(-1.2, -0.6), near_arm_behind_head=True,
        arm_n=ik(LEDGE_X + 0.4, 28.2, prefer=(-1.0, 0.0)),
        arm_f=ik(LEDGE_X - 0.2, 27.6, prefer=(-1.0, 0.0)),
        leg_n=fk(6 + 5 * swing, 2 + 7 * swing, toe=60),
        leg_f=fk(-2 + 5 * swing, -8 + 7 * swing, toe=50),
        scarf_angle=82, scarf_wave=0.6, scarf_phase=t,
    )


def anim_hang() -> list[Pose]:
    return [hang_pose(t) for t in cycle(4)]


def anim_ledge_climb() -> list[Pose]:
    """Drawn in place: the runtime moves the body up and over the ledge."""
    return [
        hang_pose(0.0),
        Pose(hip=(0.6, 13.4), lean=10, head="effort", near_arm_behind_head=True,
             arm_n=ik(LEDGE_X + 0.2, 22.0, prefer=(-1.0, 0.3)), arm_f=ik(LEDGE_X - 0.4, 22.6, prefer=(-1.0, 0.3)),
             leg_n=fk(52, 0, toe=80), leg_f=fk(6, -16, toe=60), scarf_angle=70),
        Pose(hip=(1.4, 12.6), lean=24, head="effort",
             arm_n=ik(LEDGE_X + 0.6, 14.2, prefer=(-1.0, 1.0)), arm_f=ik(LEDGE_X, 14.6, prefer=(-1.0, 1.0)),
             leg_n=ik(4.6, 13.6, prefer=(0.3, 1.0), toe=90), leg_f=fk(-4, -26, toe=50), scarf_angle=64),
        Pose(hip=(1.6, 10.4), lean=30, head="effort",
             arm_n=fk(40, 70), arm_f=fk(30, 60),
             leg_n=ik(4.4, 6.6, prefer=(0.3, 1.0), toe=90), leg_f=ik(-1.6, 3.0, prefer=(1.0, 0.0), toe=60),
             scarf_angle=56),
        Pose(hip=(0.8, 7.8), lean=26, arm_n=fk(22, 50), arm_f=fk(16, 40),
             leg_n=planted(3.0), leg_f=planted(-1.4), scarf_angle=60),
        Pose(hip=(0.4, 10.6), lean=6, arm_n=fk(-2, 20), arm_f=fk(10, 30),
             leg_n=planted(2.0), leg_f=planted(-1.6), scarf_angle=70),
    ]


BLOCK_X = 6.6  # push/pull blocks touch the body here


def anim_push() -> list[Pose]:
    poses = []
    for i, t in enumerate(cycle(8)):
        pose = locomotion(t, 2.4, 1.4, 10.2, 0.4, 22.0, 0.0, 0.0, foot_offset=-2.4,
                          scarf_angle=60, scarf_wave=0.6)
        pose.arm_n = ik(BLOCK_X, 12.4, prefer=(0.0, -1.0))
        pose.arm_f = ik(BLOCK_X - 0.4, 13.6, prefer=(0.0, -1.0))
        pose.head = "effort" if i % 4 < 2 else "side"
        poses.append(pose)
    return poses


def anim_push_idle() -> list[Pose]:
    poses = []
    for i in range(6):
        breath = 0.5 if i in (2, 3, 4) else 0.0
        poses.append(Pose(hip=(0.0, 10.8 - breath), lean=14 + breath * 2,
                          leg_n=planted(1.2), leg_f=planted(-2.6),
                          arm_n=ik(BLOCK_X, 12.8, prefer=(0.0, -1.0)),
                          arm_f=ik(BLOCK_X - 0.4, 14.0, prefer=(0.0, -1.0)),
                          scarf_angle=70, scarf_wave=0.5, scarf_phase=i / 6))
    return poses


def anim_pull() -> list[Pose]:
    poses = []
    for t in cycle(6):
        # walking backwards: run the gait in reverse
        pose = locomotion(1.0 - t, 2.4, 1.2, 10.4, 0.4, -14.0, 0.0, 0.0, foot_offset=-0.8,
                          scarf_angle=64, scarf_wave=0.6)
        pose.arm_n = ik(BLOCK_X, 13.6, prefer=(0.0, -1.0))
        pose.arm_f = ik(BLOCK_X - 0.4, 14.8, prefer=(0.0, -1.0))
        pose.head = "effort"
        poses.append(pose)
    return poses


def anim_punch_jab() -> list[Pose]:
    return [
        guard_stance(),
        guard_stance(hip=(-0.4, 10.7), lean=6, arm_n=ik(2.0, 17.0, prefer=(0.0, -1.0))),
        guard_stance(hip=(0.6, 10.5), lean=14, arm_n=fk(90, 90), head="effort",
                     fx=[("impact", (11.2, 17.0), 2)]),
        guard_stance(hip=(0.6, 10.5), lean=14, arm_n=fk(88, 90), head="effort",
                     fx=[("puff", (11.2, 17.0), 2.2)]),
        guard_stance(hip=(0.2, 10.6), lean=10, arm_n=ik(5.6, 17.6, prefer=(0.0, -1.0))),
        guard_stance(),
    ]


def anim_punch() -> list[Pose]:
    lunge = dict(leg_n=planted(5.0), leg_f=planted(-3.2), head="effort",
                 arm_n=fk(88, 90), arm_f=ik(1.6, 14.8, prefer=(0.0, -1.0)))
    return [
        guard_stance(),
        guard_stance(hip=(-0.8, 10.8), lean=2, arm_n=ik(-0.6, 16.4, prefer=(0.0, -1.0)),
                     arm_f=ik(4.2, 17.6, prefer=(0.0, -1.0))),
        guard_stance(hip=(1.2, 10.4), lean=12, leg_n=planted(4.8), leg_f=planted(-3.0),
                     arm_n=ik(3.6, 17.0, prefer=(0.0, -1.0)), arm_f=ik(3.0, 16.2, prefer=(0.0, -1.0))),
        guard_stance(hip=(1.8, 10.2), lean=20, fx=[("impact", (13.6, 17.0), 3)], **lunge),
        guard_stance(hip=(1.8, 10.2), lean=20,
                     fx=[("puff", (13.6, 17.0), 3.2), ("spark", (15.2, 19.2)), ("spark", (15.0, 14.6))],
                     **lunge),
        guard_stance(hip=(1.2, 10.4), lean=14, leg_n=planted(4.6), leg_f=planted(-3.0),
                     arm_n=ik(6.4, 17.6, prefer=(0.0, -1.0))),
        guard_stance(hip=(0.4, 10.6), lean=10, leg_n=planted(3.4)),
        guard_stance(),
    ]


def anim_punch_cross() -> list[Pose]:
    cross = dict(head="effort", leg_n=planted(3.6), arm_n=ik(1.8, 16.0, prefer=(0.0, -1.0)), arm_f=fk(88, 90))
    return [
        guard_stance(),
        guard_stance(hip=(-0.4, 10.7), lean=4, arm_n=ik(4.8, 17.8, prefer=(0.0, -1.0)),
                     arm_f=ik(-0.8, 16.2, prefer=(0.0, -1.0))),
        guard_stance(hip=(1.0, 10.4), lean=16, head="effort", arm_n=ik(2.2, 16.4, prefer=(0.0, -1.0)),
                     arm_f=fk(84, 88)),
        guard_stance(hip=(1.4, 10.3), lean=20, fx=[("impact", (12.4, 17.6), 3)], **cross),
        guard_stance(hip=(1.4, 10.3), lean=20, fx=[("puff", (12.4, 17.6), 2.8)], **cross),
        guard_stance(hip=(0.6, 10.5), lean=12, arm_f=ik(5.2, 17.4, prefer=(0.0, -1.0))),
        guard_stance(),
    ]


def sword(angle: float, **extra) -> dict:
    prop = {"kind": "sword", "angle": angle}
    prop.update(extra)
    return prop


def anim_sword_attack() -> list[Pose]:
    shoulder = (1.2, 17.0)
    return [
        guard_stance(arm_n=ik(3.8, 13.6, prefer=(0.0, -1.0)), props=[sword(58)]),
        guard_stance(hip=(-0.6, 10.8), lean=-4, arm_n=fk(158, 196), arm_f=fk(40, 70),
                     props=[sword(165)], head="effort", near_arm_behind_head=True),
        guard_stance(hip=(0.6, 10.5), lean=10, arm_n=fk(122, 112), arm_f=fk(-20, 10),
                     props=[sword(55)], head="effort",
                     fx=[("arc", shoulder, 12.0, 160, 55, 3.0)]),
        guard_stance(hip=(1.4, 10.2), lean=18, leg_n=planted(4.0), arm_n=fk(78, 62), arm_f=fk(-30, 0),
                     props=[sword(-32)], head="effort",
                     fx=[("arc", shoulder, 12.0, 160, -32, 3.6)]),
        guard_stance(hip=(1.4, 10.2), lean=16, leg_n=planted(4.0), arm_n=fk(70, 56), arm_f=fk(-24, 6),
                     props=[sword(-40)],
                     fx=[("arc", shoulder, 12.5, 40, -40, 2.4)]),
        guard_stance(hip=(0.6, 10.5), lean=10, arm_n=ik(4.2, 13.4, prefer=(0.0, -1.0)), props=[sword(44)]),
    ]


def anim_sword_idle() -> list[Pose]:
    poses = []
    for i, pose in enumerate(anim_idle()):
        pose.arm_n = ik(3.4, 12.0 - (0.9 if i in (3, 4, 5) else 0.0), prefer=(0.0, -1.0))
        pose.props = [sword(-40, length=9.0)]
        poses.append(pose)
    return poses


def anim_sword_run() -> list[Pose]:
    poses = []
    for pose in anim_run():
        pose.arm_n = fk(-36, 20)
        pose.props = [sword(196, z=8)]
        poses.append(pose)
    return poses


def anim_sword_stab() -> list[Pose]:
    ready = dict(leg_n=planted(3.0), leg_f=planted(-2.8))
    lunge = dict(hip=(3.6, 9.4), lean=24, leg_n=planted(9.4), leg_f=planted(-4.6), head="effort",
                 arm_n=fk(94, 92), arm_f=fk(-70, -60), props=[sword(-2)])
    return [
        guard_stance(arm_n=ik(3.0, 12.6, prefer=(0.0, -1.0)), props=[sword(4)], **ready),
        guard_stance(hip=(-1.2, 10.8), lean=4, arm_n=ik(-1.6, 13.4, prefer=(0.0, -1.0)),
                     props=[sword(2)], head="effort", **ready),
        guard_stance(fx=[("streak", (16.0, 15.2), 14)], **lunge),
        guard_stance(fx=[("impact", (27.4, 15.0), 2)], **lunge),
        guard_stance(hip=(1.6, 10.2), lean=14, leg_n=planted(6.0), leg_f=planted(-3.6),
                     arm_n=ik(5.6, 14.4, prefer=(0.0, -1.0)), props=[sword(2)]),
        guard_stance(arm_n=ik(3.0, 12.6, prefer=(0.0, -1.0)), props=[sword(4)], **ready),
    ]


def gun(angle: float = 0.0, hand: str = "near") -> dict:
    return {"kind": "gun", "angle": angle, "hand": hand}


def two_hand_pose(near_xy, far_xy, angle: float, **overrides) -> Pose:
    pose = Pose(hip=(0.0, 10.9), lean=4, leg_n=planted(2.8), leg_f=planted(-2.4),
                arm_n=ik(near_xy[0], near_xy[1], prefer=(0.0, -1.0)),
                arm_f=ik(far_xy[0], far_xy[1], prefer=(0.0, -1.0)),
                props=[gun(angle)], scarf_angle=58)
    return with_overrides(pose, overrides)


def anim_shoot() -> list[Pose]:
    aim = two_hand_pose((5.6, 16.6), (4.4, 16.0), 0.0)
    fire = two_hand_pose((5.0, 17.0), (3.8, 16.4), 6.0, hip=(-0.4, 10.9), lean=0, head="effort")
    fire.fx = [("flash", muzzle(fire, angle=6.0), 2)]
    recoil = two_hand_pose((4.8, 16.8), (3.6, 16.2), 3.0, hip=(-0.3, 10.9), lean=1)
    recoil.fx = [("puff", muzzle(recoil, angle=3.0), 1.4)]
    return [
        two_hand_pose((4.2, 13.8), (3.2, 13.4), -22.0),
        aim,
        fire,
        recoil,
        two_hand_pose((5.4, 16.6), (4.2, 16.0), 0.0),
        aim,
    ]


def anim_running_aim(shooting: bool) -> list[Pose]:
    poses = []
    for i, pose in enumerate(anim_run()):
        pose.lean = 10
        pose.arm_n = ik(6.4, 16.0, prefer=(0.0, -1.0))
        pose.props = [gun(0.0)]
        if shooting and i % 4 in (0, 1):
            pose.fx = [("flash", muzzle(pose), 2 if i % 4 == 0 else 1)]
        poses.append(pose)
    return poses


def anim_air_spin() -> list[Pose]:
    pivot = (0.8, 12.6)
    lift = dict(hip=(0.0, 13.0))
    poses = [tuck_pose(fx=[("puff", (0.0, 2.6), 3.0)], scarf_angle=-30, **lift)]
    sweeps = ((150, 40), (60, -50), (-30, -140))
    for rot, (start, end) in zip((3, 2, 1), sweeps):
        poses.append(tuck_pose(rot=rot, rot_pivot=pivot, scarf_angle=-20,
                               fx=[("arc", pivot, 9.0, start, end, 2.2)], **lift))
    poses.append(tuck_pose(fx=[("arc", pivot, 9.0, 120, 20, 1.6)], scarf_angle=-30, **lift))
    poses.append(Pose(hip=(0.0, 12.4), lean=6, arm_n=fk(110, 130), arm_f=fk(-60, -40),
                      leg_n=fk(30, 6, toe=70), leg_f=fk(-6, -22, toe=55), scarf_angle=-40, scarf_wave=1.0))
    return poses


def anim_climb_back() -> list[Pose]:
    """Ladder climb seen from behind: hand over hand, alternating knees."""
    poses = []
    for t in cycle(6):
        s = math.cos(2 * math.pi * t)  # +1 right hand high, -1 left hand high
        poses.append(Pose(
            view="back", head="back", head_offset=(0.0, -1.2),
            hip=(0.0, STAND_HIP_Y + 0.4 - 0.5 * abs(math.sin(2 * math.pi * t))),
            arm_n=ik(4.4 + 0.4 * s, 25.0 + 3.2 * s, prefer=(1.0, -0.3)),
            arm_f=ik(-4.4 + 0.4 * s, 25.0 - 3.2 * s, prefer=(-1.0, -0.3)),
            leg_n=ik(1.9, 3.4 - 1.7 * s, prefer=(1.0, -0.2), toe=0),
            leg_f=ik(-1.9, 3.4 + 1.7 * s, prefer=(-1.0, -0.2), toe=0),
            scarf_wave=0.5, scarf_phase=t,
        ))
    return poses


def anim_climb_back_idle() -> list[Pose]:
    poses = []
    for i, t in enumerate(cycle(4)):
        breath = 0.5 if i in (1, 2) else 0.0
        poses.append(Pose(
            view="back", head="back", head_offset=(0.0, -1.2),
            hip=(0.0, STAND_HIP_Y + 0.4 - breath),
            arm_n=ik(4.8, 28.0, prefer=(1.0, -0.3)),
            arm_f=ik(-4.4, 22.4, prefer=(-1.0, -0.3)),
            leg_n=ik(1.9, 1.9, prefer=(1.0, -0.2), toe=0),
            leg_f=ik(-1.9, 4.8, prefer=(-1.0, -0.2), toe=0),
            scarf_wave=0.4, scarf_phase=t,
        ))
    return poses


def anim_climb_side() -> list[Pose]:
    """Climbing a wall in front (to the right), seen from the side."""
    poses = []
    for t in cycle(4):
        s = math.cos(2 * math.pi * t)
        poses.append(Pose(
            hip=(0.6, STAND_HIP_Y + 0.4), lean=-2, near_arm_behind_head=True,
            arm_n=ik(5.2, 23.4 + 3.0 * s, prefer=(-1.0, -0.4)),
            arm_f=ik(4.8, 23.4 - 3.0 * s, prefer=(-1.0, -0.4)),
            leg_n=ik(4.0, 4.0 - 1.8 * s, prefer=(1.0, 0.5), toe=95),
            leg_f=ik(3.6, 4.0 + 1.8 * s, prefer=(1.0, 0.5), toe=95),
            scarf_angle=84, scarf_wave=0.5, scarf_phase=t,
        ))
    return poses


def anim_swim() -> list[Pose]:
    poses = []
    for i, t in enumerate(cycle(8)):
        stroke = math.cos(2 * math.pi * t)
        kick = math.sin(2 * math.pi * t * 2)
        poses.append(Pose(
            hip=(-1.6, 12.0), lean=64,
            arm_n=fk(76 + 52 * stroke, 100 + 40 * stroke),
            arm_f=fk(76 - 52 * stroke, 100 - 40 * stroke),
            leg_n=fk(-60 + 12 * kick, -74 + 16 * kick, toe=-80),
            leg_f=fk(-60 - 12 * kick, -74 - 16 * kick, toe=-80),
            scarf_angle=4, scarf_wave=1.0, scarf_phase=t * 2,
            fx=[("bubble", (9.0 + (i % 2), 22.0 + i * 0.6), 2 if i % 4 == 0 else 1),
                ("bubble", (-11.0 - (i % 3), 6.0 + i * 0.5), 1)],
        ))
    return poses


def anim_swim_idle() -> list[Pose]:
    poses = []
    for i, t in enumerate(cycle(6)):
        s, c = math.sin(2 * math.pi * t), math.cos(2 * math.pi * t)
        poses.append(Pose(
            hip=(0.0, 12.0), lean=6,
            arm_n=fk(64 + 18 * s, 92 + 20 * s),
            arm_f=fk(-44 - 18 * s, -14 - 20 * s),
            leg_n=ik(1.8 + 1.2 * c, 3.6 + 1.2 * s, toe=70),
            leg_f=ik(-1.6 - 1.2 * c, 3.6 - 1.2 * s, toe=60),
            scarf_angle=-64, scarf_wave=0.8, scarf_phase=t,
            fx=[("bubble", (4.6, 28.0 + i), 2 if i % 3 == 0 else 1),
                ("bubble", (-3.6 + (i % 2), 26.0 + (i * 1.5) % 7), 1)],
        ))
    return poses


def anim_grapple() -> list[Pose]:
    poses = []
    for t in cycle(4):
        s = math.sin(2 * math.pi * t)
        poses.append(Pose(
            hip=(-1.2, 14.6), lean=8 + 4 * s,
            head_offset=(-1.4, -0.6), near_arm_behind_head=True,
            arm_n=ik(5.4, 29.0, prefer=(-1.0, 0.0)),
            arm_f=ik(4.8, 27.8, prefer=(-1.0, 0.0)),
            leg_n=fk(10 + 8 * s, 2 + 10 * s, toe=60),
            leg_f=fk(2 + 8 * s, -8 + 10 * s, toe=50),
            scarf_angle=50 - 20 * s, scarf_wave=0.8, scarf_phase=t,
        ))
    return poses


# Sheet id (as listed in generate_player_sprite_frames.SHEETS) -> poses.
ANIMATION_BUILDERS = {
    "idle": anim_idle,
    "walk": anim_walk,
    "run": anim_run,
    "jump": anim_jump,
    "dash": anim_dash,
    "death": anim_death,
    "hurt_damaged": anim_hurt,
    "land": anim_land,
    "ledge_grab_climb": anim_ledge_climb,
    "ledge_hang": anim_hang,
    "pull": anim_pull,
    "punch": anim_punch,
    "punch_cross": anim_punch_cross,
    "punch_jab": anim_punch_jab,
    "push": anim_push,
    "pushpull_idle_state": anim_push_idle,
    "roll": anim_roll,
    "running_aiming": lambda: anim_running_aim(False),
    "running_shooting": lambda: anim_running_aim(True),
    "shooting_two_handed": anim_shoot,
    "slide": anim_slide,
    "sword_attack": anim_sword_attack,
    "sword_idle": anim_sword_idle,
    "sword_run": anim_sword_run,
    "sword_stab": anim_sword_stab,
    "climb_facing_back_of_player": anim_climb_back,
    "climb_back_idle": anim_climb_back_idle,
    "climb_facing_side_of_player": anim_climb_side,
    "crouch_idle": anim_crouch_idle,
    "crouch_walk": anim_crouch_walk,
    "air_spin": anim_air_spin,
    "wall_land": anim_wall_land,
    "wall_slide": anim_wall_slide,
    "swim": anim_swim,
    "swim_idle": anim_swim_idle,
    "grapple": anim_grapple,
}

# Import settings read by generate_player_sprite_frames.py from pack.json.
PACK_SETTINGS = {
    "name": "Wayfarer",
    "generator": "developer/tools/generate_player_model_pack.py",
    "baseline_bottom_margin": BOTTOM_MARGIN * 4,
    "keep_geometry": True,
    "animations": {
        # Hold the rising frame while airborne; fall loops the three fall frames.
        "jump": {"indices": [0, 1, 2]},
        "fall": {"source": "jump", "indices": [3, 4, 5], "fps": 10, "playback": "loop"},
        "land": {"fps": 18},
        "ledge_grab_climb": {"fps": 13},
    },
}


def use_mannequin() -> None:
    """Draw the colour-coded template: no costume, its own folder and pack name."""
    global MANNEQUIN, PACK_DIR
    MANNEQUIN = True
    PACK_DIR = MANNEQUIN_DIR
    MATERIALS.update(MANNEQUIN_MATERIALS)
    PACK_SETTINGS["name"] = "Mannequin"


# ---------------------------------------------------------------------------
# Rendering, validation and output
# ---------------------------------------------------------------------------


def load_importer():
    import importlib.util

    spec = importlib.util.spec_from_file_location("generate_player_sprite_frames", IMPORTER)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def render_sheet(poses: list[Pose], width: int, height: int) -> list[Image.Image]:
    frames = []
    for pose in poses:
        frame = Frame(width, height)
        draw_pose(frame, pose)
        frames.append(frame.to_image())
    return frames


def validate_frames(sheet_id: str, frames: list[Image.Image]) -> list[str]:
    problems = []
    for index, image in enumerate(frames):
        bbox = image.getchannel("A").getbbox()
        if bbox is None:
            problems.append(f"{sheet_id}[{index}] is empty")
            continue
        width, height = image.size
        ground_row = height - BOTTOM_MARGIN - 1
        if bbox[3] - 1 > ground_row:
            problems.append(f"{sheet_id}[{index}] reaches {bbox[3] - 1 - ground_row}px below the ground line")
        if bbox[1] < ground_row + 1 - MAX_ROWS_ABOVE_GROUND:
            problems.append(f"{sheet_id}[{index}] is taller than {MAX_ROWS_ABOVE_GROUND} rows above the ground")
        centre = width / 2.0
        if bbox[0] < centre - MAX_HALF_WIDTH or bbox[2] > centre + MAX_HALF_WIDTH:
            problems.append(f"{sheet_id}[{index}] is wider than +/-{MAX_HALF_WIDTH}px from the frame centre")
        if bbox[0] <= 0 or bbox[2] >= width or bbox[1] <= 0:
            problems.append(f"{sheet_id}[{index}] touches the frame edge")
    return problems


def sheet_specs(importer) -> dict:
    return {spec.id: spec for spec in importer.SHEETS}


def render_selected(importer, ids) -> tuple[dict[str, list[Image.Image]], list[str]]:
    known = sheet_specs(importer)
    sheets, problems = {}, []
    for sheet_id in ids:
        spec = known.get(sheet_id)
        if spec is None:
            raise SystemExit(f"Sheet '{sheet_id}' is not listed in {IMPORTER.name} SHEETS")
        # Draw in the original pixel grid; the saved source sheets use 4x4
        # blocks at in-game size, including the wider attack cells.
        frames = render_sheet(ANIMATION_BUILDERS[sheet_id](),
                              spec.frame_width // importer.TEMPLATE_PIXEL_SCALE,
                              spec.frame_height // importer.TEMPLATE_PIXEL_SCALE)
        problems.extend(validate_frames(sheet_id, frames))
        sheets[sheet_id] = frames
    return sheets, problems


def write_pack(importer, sheets: dict[str, list[Image.Image]]) -> None:
    known = sheet_specs(importer)
    PACK_DIR.mkdir(parents=True, exist_ok=True)
    for sheet_id, frames in sheets.items():
        spec = known[sheet_id]
        frame_width, frame_height = frames[0].size
        sheet = Image.new("RGBA", (frame_width * len(frames), frame_height), (0, 0, 0, 0))
        for index, frame in enumerate(frames):
            sheet.alpha_composite(frame, (index * frame_width, 0))
        sheet = sheet.resize((sheet.width * importer.TEMPLATE_PIXEL_SCALE,
                              sheet.height * importer.TEMPLATE_PIXEL_SCALE), Image.Resampling.NEAREST)
        path = PACK_DIR / spec.source_rel
        path.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(path)
    with (PACK_DIR / "pack.json").open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(PACK_SETTINGS, handle, indent=2)
        handle.write("\n")


def write_preview(sheets: dict[str, list[Image.Image]], path: Path, zoom: int = 3) -> None:
    rows = list(sheets.items())
    cell_w = max(img.size[0] for _, frames in rows for img in frames)
    cell_h = max(img.size[1] for _, frames in rows for img in frames)
    cols = max(len(frames) for _, frames in rows)
    sheet = Image.new("RGBA", (cols * (cell_w + 2), len(rows) * (cell_h + 2)), (70, 74, 96, 255))
    for r, (_name, frames) in enumerate(rows):
        for c, img in enumerate(frames):
            x = c * (cell_w + 2) + (cell_w - img.size[0]) // 2
            y = r * (cell_h + 2) + (cell_h - img.size[1])
            ground = y + img.size[1] - BOTTOM_MARGIN
            for gx in range(x, x + img.size[0]):
                sheet.putpixel((gx, ground), (96, 130, 96, 255))
            sheet.alpha_composite(img, (x, y))
    sheet = sheet.resize((sheet.size[0] * zoom, sheet.size[1] * zoom), Image.NEAREST)
    sheet.save(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-import", action="store_true",
                        help="Only write the source pack; do not regenerate the game frames and atlas.")
    parser.add_argument("--preview", type=Path, default=None,
                        help="Also write a zoomed contact sheet of the drawn animations to this PNG path.")
    parser.add_argument("--only", nargs="*", default=None,
                        help="Preview only these sheet ids (requires --preview; writes nothing else).")
    parser.add_argument("--mannequin", action="store_true",
                        help="Draw the colour-coded Mannequin template pack instead of Wayfarer. "
                             "It is never imported; the game keeps its current player.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.mannequin:
        use_mannequin()
    importer = load_importer()
    if args.only:
        if not args.preview:
            raise SystemExit("--only previews a subset; pass --preview <png> as well.")
        sheets, problems = render_selected(importer, args.only)
        for problem in problems:
            print("WARNING:", problem)
        write_preview(sheets, args.preview)
        return

    sheets, problems = render_selected(importer, ANIMATION_BUILDERS)
    missing = [spec.id for spec in importer.SHEETS if not spec.optional and spec.id not in sheets]
    if missing:
        problems.append("required sheets not drawn: " + ", ".join(missing))
    if problems:
        raise SystemExit("Player model validation failed:\n  " + "\n  ".join(problems))
    write_pack(importer, sheets)
    total = sum(len(frames) for frames in sheets.values())
    print(f"Wrote {len(sheets)} sheets ({total} frames) to {PACK_DIR}")
    if args.preview:
        write_preview(sheets, args.preview)
        print(f"Wrote preview to {args.preview}")
    if args.no_import or args.mannequin:
        return
    command = [sys.executable, str(IMPORTER), "--source", str(PACK_DIR)]
    print("Importing:", " ".join(command))
    subprocess.run(command, check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
