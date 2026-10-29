#!/usr/bin/env python3
"""Generates Rovloc's seamless PBR textures from tools/textures/manifest.json.

    python3 tools/textures/generate.py                 every map + out/meta.json + out/preview.png
    python3 tools/textures/generate.py --only CheckerTile,RustedMetal --detail
    python3 tools/textures/generate.py --check         validate manifest <-> Palette.luau only (no images)

Output (default tools/textures/out, git-ignored): <Id>_<Map>.png (1024 x 1024; colour RGB, or RGBA for overlays;
normal RGB in the OpenGL tangent-space convention Roblox uses; roughness / metalness 8-bit grey), meta.json (the
sha256 of every map and each texture's reference albedo, read by upload.py), preview.png (every surface lit at game
scale, tinted with its palette colour) and with --detail preview_<Id>.png (the maps side by side, 1:1 crops).
Every recipe is seeded from the manifest, so the same inputs give the same pixels.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from materials import RECIPES, Surface  # noqa: E402
from texlib import Field, normal_map, to_u8  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
PALETTE = os.path.join(ROOT, "src", "ReplicatedStorage", "Shared", "World", "ProceduralWorldBuilder", "Palette.luau")
MAPS = ("ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap")


def load_manifest(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def parse_palette(path: str = PALETTE):
    """(entries, textured): key -> (material, (r, g, b)) and key -> texture id, read from Palette.luau."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    entries = {
        m.group(1): (m.group(2), (int(m.group(3)), int(m.group(4)), int(m.group(5))))
        for m in re.finditer(r"^\t(\w+) = entry\(Enum\.Material\.(\w+), (\d+), (\d+), (\d+),", text, re.M)
    }
    block = re.search(r"local textured: \{ \[string\]: string \} = \{\n(.*?)\n\}", text, re.S)
    textured = dict(re.findall(r'^\t(\w+) = "(\w+)",', block.group(1), re.M)) if block else {}
    return entries, textured


def check(manifest: dict) -> list[str]:
    errors: list[str] = []
    ids = [m["id"] for m in manifest["materials"]]
    if len(ids) != len(set(ids)):
        errors.append("duplicate material ids")
    by_id = {m["id"]: m for m in manifest["materials"]}
    wanted = set()
    for m in manifest["materials"]:
        if m["id"] not in RECIPES:
            errors.append(f"{m['id']}: no recipe in materials.py")
        if m["kind"] not in ("variant", "overlay"):
            errors.append(f"{m['id']}: kind must be variant or overlay")
        if m["kind"] == "variant":
            if not m.get("bases"):
                errors.append(f"{m['id']}: a variant needs bases")
            if m.get("pattern") not in ("Regular", "Organic"):
                errors.append(f"{m['id']}: pattern must be Regular or Organic")
            if not (m.get("studsPerTile", 0) > 0):
                errors.append(f"{m['id']}: studsPerTile must be positive")
        elif m.get("layout") not in ("strip", "tile") or m["maps"] != ["ColorMap"]:
            errors.append(f"{m['id']}: an overlay has layout strip|tile and only a ColorMap")
        if "ColorMap" not in m["maps"]:
            errors.append(f"{m['id']}: every texture needs a ColorMap")
        for map_name in m["maps"]:
            if map_name not in MAPS:
                errors.append(f"{m['id']}: unknown map {map_name}")
            wanted.add(f"{m['id']}/{map_name}")
    order = manifest["uploadOrder"]
    if len(order) != len(set(order)):
        errors.append("uploadOrder lists a map twice")
    for item in set(order) - wanted:
        errors.append(f"uploadOrder names {item}, which no material generates")
    for item in wanted - set(order):
        errors.append(f"{item} is missing from uploadOrder")
    entries, textured = parse_palette()
    if not textured:
        errors.append("Palette.luau: no `textured` table found")
    for key, texture in textured.items():
        if key not in entries:
            errors.append(f"Palette textured key {key} has no entry")
            continue
        m = by_id.get(texture)
        if not m or m["kind"] != "variant":
            errors.append(f"Palette key {key} names {texture}, which is not a variant in the manifest")
        elif entries[key][0] not in m["bases"]:
            errors.append(f"Palette key {key} is {entries[key][0]}, missing from {texture}'s bases {m['bases']}")
    for m in manifest["materials"]:
        if m["kind"] == "variant" and m["id"] not in textured.values():
            errors.append(f"{m['id']}: no Palette key uses it")
    return errors


# -- rendering ------------------------------------------------------------------------------------------------


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def resized(arr: np.ndarray, size: int) -> np.ndarray:
    mode = "L" if arr.ndim == 2 else ("RGBA" if arr.shape[2] == 4 else "RGB")
    img = Image.fromarray(arr, mode).resize((size, size), Image.LANCZOS)
    return np.asarray(img).astype(np.float32) / 255.0


def lit(color, normal, rough, metal, tint, light=(-0.55, 0.6, 0.58), alpha=None, backdrop=None):
    """Shades maps (float, same size) the way a key light raking from the upper left would."""
    albedo = srgb_to_linear(np.clip(color[..., :3] * tint, 0, 1))
    if backdrop is not None and alpha is not None:
        albedo = albedo * alpha[..., None] + srgb_to_linear(backdrop) * (1 - alpha[..., None])
    n = normal * 2 - 1
    n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-6
    lvec = np.array(light, np.float32)
    lvec /= np.linalg.norm(lvec)
    ndl = np.clip((n * lvec).sum(-1), 0, 1)
    h = lvec + np.array([0, 0, 1], np.float32)
    h /= np.linalg.norm(h)
    ndh = np.clip((n * h).sum(-1), 0, 1)
    r = np.clip(rough, 0.05, 1)
    a2 = (r * r) ** 2
    d = a2 / (np.pi * ((ndh * ndh) * (a2 - 1) + 1) ** 2)
    f0 = 0.04 * (1 - metal)[..., None] + albedo * metal[..., None]
    spec = f0 * (d * ndl * 0.25)[..., None]
    diffuse = albedo * (1 - metal)[..., None] * (ndl[..., None] * 2.2 + 0.35)
    ambient_spec = f0 * (0.75 - 0.5 * r)[..., None]  # a dim room reflected in the metal
    return linear_to_srgb(diffuse + spec * 2.0 + ambient_spec)


def game_view(maps: dict, tint, studs_per_tile: float, width_studs: float, height_studs: float, px_per_stud: int):
    """A width x height stud patch at px_per_stud, the texture repeating every studs_per_tile."""
    tile_px = max(8, int(round(studs_per_tile * px_per_stud)))
    w, h = int(width_studs * px_per_stud), int(height_studs * px_per_stud)
    reps = (h // tile_px + 2, w // tile_px + 2)

    def tiled(arr):
        small = resized(arr, tile_px)
        t = np.tile(small, reps + ((1,) if small.ndim == 3 else ()))
        return t[:h, :w]

    color = tiled(maps["ColorMap"])
    normal = tiled(maps["NormalMap"]) if "NormalMap" in maps else np.dstack([np.full((h, w), 0.5)] * 2 + [np.ones((h, w))])
    rough = tiled(maps["RoughnessMap"]) if "RoughnessMap" in maps else np.full((h, w), 0.6, np.float32)
    metal = tiled(maps["MetalnessMap"]) if "MetalnessMap" in maps else np.zeros((h, w), np.float32)
    alpha = color[..., 3] if color.shape[2] == 4 else None
    return lit(color, normal, rough, metal, tint, alpha=alpha, backdrop=np.array([0.42, 0.40, 0.36]) if alpha is not None else None)


def label(img: Image.Image, text: str, xy=(6, 4)):
    draw = ImageDraw.Draw(img)
    x, y = xy
    draw.rectangle([x - 3, y - 2, x + 7 * len(text) + 3, y + 13], fill=(0, 0, 0))
    draw.text((x, y), text, fill=(235, 235, 225))


# -- main -----------------------------------------------------------------------------------------------------


def surface_maps(m: dict, s: Surface) -> dict[str, np.ndarray]:
    out: dict[str, np.ndarray] = {}
    if s.alpha is not None:
        out["ColorMap"] = np.dstack([to_u8(s.color), to_u8(s.alpha)])
    else:
        out["ColorMap"] = to_u8(s.color)
    if "NormalMap" in m["maps"]:
        out["NormalMap"] = normal_map(s.height, s.normal_strength)
    if "RoughnessMap" in m["maps"]:
        out["RoughnessMap"] = to_u8(s.roughness)
    if "MetalnessMap" in m["maps"]:
        out["MetalnessMap"] = to_u8(s.metalness)
    return out


def seam_ratio(arr: np.ndarray, vertical: bool = True) -> float:
    """The wrap-around step against the largest ordinary column (row) step: <= 1 means no seam can show."""
    a = arr.astype(np.float32)
    if a.ndim == 2:
        a = a[..., None]
    worst = 0.0
    for axis in (1, 0) if vertical else (1,):
        steps = np.abs(np.diff(a, axis=axis)).mean(axis=(1 - axis, 2))
        wrap = np.abs(np.take(a, 0, axis=axis) - np.take(a, -1, axis=axis)).mean()
        worst = max(worst, float(wrap / max(np.percentile(steps, 99.5), 1e-6)))
    return worst


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--only", default="", help="comma-separated material ids")
    ap.add_argument("--preview", default="", help="preview sheet path (default <out>/preview.png)")
    ap.add_argument("--no-preview", action="store_true")
    ap.add_argument("--detail", action="store_true", help="also write preview_<Id>.png per material")
    ap.add_argument("--check", action="store_true", help="validate manifest and Palette only")
    args = ap.parse_args()

    manifest = load_manifest(args.manifest)
    errors = check(manifest)
    if errors:
        for e in errors:
            print("manifest error:", e)
        return 1
    if args.check:
        print(f"manifest ok: {len(manifest['materials'])} textures, {len(manifest['uploadOrder'])} maps")
        return 0

    only = {s for s in args.only.split(",") if s}
    os.makedirs(args.out, exist_ok=True)
    meta_path = os.path.join(args.out, "meta.json")
    meta = {}
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
    entries, textured = parse_palette()
    size = manifest["size"]
    views = []
    for m in manifest["materials"]:
        if only and m["id"] not in only:
            continue
        started = time.time()
        surface = RECIPES[m["id"]](Field(m["seed"], size))
        maps = surface_maps(m, surface)
        files = {}
        for map_name, arr in maps.items():
            path = os.path.join(args.out, f"{m['id']}_{map_name}.png")
            Image.fromarray(arr).save(path, optimize=True)
            with open(path, "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
            ratio = seam_ratio(arr, m.get("layout") != "strip")
            if ratio > 1.15:
                print(f"  seam warning: {m['id']} {map_name} wrap step {ratio:.2f}x a normal step")
            files[map_name] = {"file": os.path.basename(path), "sha256": digest, "bytes": os.path.getsize(path)}
        ref = surface.reference if surface.reference is not None else np.ones(3, np.float32)
        meta[m["id"]] = {"reference": [round(float(c), 4) for c in ref], "files": files}
        keys = [k for k, t in textured.items() if t == m["id"]]
        print(f"{m['id']}: {', '.join(files)} in {time.time() - started:.1f}s" + (f" (keys {', '.join(keys)})" if keys else ""))
        views.append((m, maps, ref, keys))
        if args.detail:
            detail(m, maps, ref, keys, entries, os.path.join(args.out, f"preview_{m['id']}.png"))
    with open(meta_path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2, sort_keys=True)
        fh.write("\n")
    if not args.no_preview and views:
        sheet(views, entries, args.preview or os.path.join(args.out, "preview.png"))
    return 0


def tint_for(keys, entries, ref):
    if not keys:
        return np.ones(3, np.float32)
    rgb = np.array(entries[keys[0]][1], np.float32) / 255.0
    return np.clip(rgb / np.maximum(ref, 1e-3), 0, 1)


def sheet(views, entries, path):
    cell_w, cell_h, px = 520, 340, 20
    cols = 3
    rows = (len(views) + cols - 1) // cols
    img = Image.new("RGB", (cols * cell_w, rows * cell_h), (16, 16, 16))
    for i, (m, maps, ref, keys) in enumerate(views):
        spt = m.get("studsPerTile", 8)
        if m["kind"] == "overlay":
            spt = 8 if m["layout"] == "tile" else 16
        view = game_view(maps, tint_for(keys, entries, ref), spt, (cell_w - 8) / px, (cell_h - 8) / px, px)
        tile = Image.fromarray(np.clip(np.round(view * 255), 0, 255).astype(np.uint8))
        x, y = (i % cols) * cell_w + 4, (i // cols) * cell_h + 4
        img.paste(tile, (x, y))
        label(img, f"{m['id']}  {spt:g} studs/tile" + (f"  as {keys[0]}" if keys else ""), (x + 6, y + 4))
    img.save(path)
    print("preview:", path)


def detail(m, maps, ref, keys, entries, path):
    s = 512
    tint = tint_for(keys, entries, ref)
    panels = [maps["ColorMap"][..., :3]]
    for name in ("NormalMap", "RoughnessMap", "MetalnessMap"):
        if name in maps:
            panels.append(maps[name])
    crop = {k: v[:s, :s] for k, v in maps.items()}
    full = {k: (v[:s, :s].astype(np.float32) / 255.0) for k, v in crop.items()}
    h = s
    normal = full.get("NormalMap", np.dstack([np.full((h, h), 0.5)] * 2 + [np.ones((h, h))]))
    rough = full.get("RoughnessMap", np.full((h, h), 0.6, np.float32))
    metal = full.get("MetalnessMap", np.zeros((h, h), np.float32))
    color = full["ColorMap"]
    alpha = color[..., 3] if color.shape[2] == 4 else None
    shaded = lit(color, normal, rough, metal, tint, alpha=alpha, backdrop=np.array([0.42, 0.40, 0.36]) if alpha is not None else None)
    img = Image.new("RGB", (s * (len(panels) + 1), s), (0, 0, 0))
    for i, p in enumerate(panels):
        pim = Image.fromarray(p).resize((s, s), Image.LANCZOS).convert("RGB")
        img.paste(pim, (i * s, 0))
    img.paste(Image.fromarray(np.clip(np.round(shaded * 255), 0, 255).astype(np.uint8)), (len(panels) * s, 0))
    label(img, f"{m['id']}: maps at 1/2 scale, lit 1:1 crop", (6, 4))
    img.save(path)


if __name__ == "__main__":
    sys.exit(main())
