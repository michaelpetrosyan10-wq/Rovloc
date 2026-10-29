#!/usr/bin/env python3
"""Packs the generated PBR textures (tools/textures) into small WebP maps for the web build.

    python3 tools/textures.py [--size 512] [--quality 80] [--out build/textures]

Reads tools/textures/manifest.json and the generator's output (tools/textures/out/<Id>_<Map>.png, 1024 px; runs
tools/textures/generate.py first when a map is missing) and writes, per variant texture:

    <Id>_color.webp    sRGB albedo (RGB), multiplied in the shader by the part colour (already divided by the
                       texture's reference albedo by Palette.colorFor, exactly like Roblox's MaterialVariant)
    <Id>_normal.webp   tangent-space normal (RGB, OpenGL convention: +Y up, three.js's default)
    <Id>_orm.webp      R = 1 (no AO), G = roughness, B = metalness (0 without a metalness map): three.js ORM layout

plus textures.json: { textures: { <Id>: { studsPerTile, reference, maps: { color, normal, orm } } }, bytes }.
Overlay textures (WallGrime, FloorDirt, ...) are not used by the game and are skipped. Deterministic: the same
inputs give the same files (WebP encoding is deterministic for fixed settings).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.dirname(HERE)
ROOT = os.path.dirname(WEB)
GEN = os.path.join(ROOT, "tools", "textures")
MANIFEST = os.path.join(GEN, "manifest.json")
SOURCE = os.path.join(GEN, "out")


def ensure_generated(manifest: dict) -> None:
    missing = []
    for m in manifest["materials"]:
        if m["kind"] != "variant":
            continue
        for kind in m["maps"]:
            if not os.path.exists(os.path.join(SOURCE, f"{m['id']}_{kind}.png")):
                missing.append(m["id"])
                break
    if missing:
        print(f"textures: generating {', '.join(sorted(set(missing)))}")
        subprocess.run([sys.executable, os.path.join(GEN, "generate.py"), "--only", ",".join(sorted(set(missing)))], check=True)


def load(path: str, mode: str, size: int) -> Image.Image:
    img = Image.open(path).convert(mode)
    if img.size != (size, size):
        img = img.resize((size, size), Image.Resampling.LANCZOS)
    return img


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--size", type=int, default=512, help="colour map size in pixels")
    parser.add_argument("--normal-size", type=int, default=512, help="normal map size in pixels")
    parser.add_argument("--orm-size", type=int, default=256, help="roughness / metalness map size in pixels")
    parser.add_argument("--quality", type=int, default=80, help="WebP quality for colour maps")
    parser.add_argument("--normal-quality", type=int, default=72, help="WebP quality for normal maps")
    parser.add_argument("--out", default=os.path.join(WEB, "build", "textures"))
    args = parser.parse_args()

    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)
    ensure_generated(manifest)
    meta_path = os.path.join(SOURCE, "meta.json")
    gen_meta = {}
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as fh:
            gen_meta = json.load(fh)

    os.makedirs(args.out, exist_ok=True)
    out = {"textures": {}, "bytes": 0, "settings": vars(args)}
    total = 0
    for m in manifest["materials"]:
        if m["kind"] != "variant":
            continue
        tid = m["id"]
        maps = {}
        color = load(os.path.join(SOURCE, f"{tid}_ColorMap.png"), "RGB", args.size)
        name = f"{tid}_color.webp"
        color.save(os.path.join(args.out, name), "WEBP", quality=args.quality, method=6)
        maps["color"] = f"textures/{name}"

        if "NormalMap" in m["maps"]:
            normal = load(os.path.join(SOURCE, f"{tid}_NormalMap.png"), "RGB", args.normal_size)
            name = f"{tid}_normal.webp"
            normal.save(os.path.join(args.out, name), "WEBP", quality=args.normal_quality, method=6)
            maps["normal"] = f"textures/{name}"

        if "RoughnessMap" in m["maps"] or "MetalnessMap" in m["maps"]:
            size = args.orm_size
            rough = (
                load(os.path.join(SOURCE, f"{tid}_RoughnessMap.png"), "L", size)
                if "RoughnessMap" in m["maps"]
                else Image.new("L", (size, size), 180)
            )
            metal = (
                load(os.path.join(SOURCE, f"{tid}_MetalnessMap.png"), "L", size)
                if "MetalnessMap" in m["maps"]
                else Image.new("L", (size, size), 0)
            )
            orm = Image.merge("RGB", (Image.new("L", (size, size), 255), rough, metal))
            name = f"{tid}_orm.webp"
            orm.save(os.path.join(args.out, name), "WEBP", quality=85, method=6)
            maps["orm"] = f"textures/{name}"

        size_bytes = sum(os.path.getsize(os.path.join(WEB, "build", p)) for p in maps.values())
        total += size_bytes
        reference = gen_meta.get(tid, {}).get("reference")
        out["textures"][tid] = {
            "studsPerTile": m["studsPerTile"],
            "pattern": m.get("pattern"),
            "reference": reference,
            "hasMetalness": "MetalnessMap" in m["maps"],
            "maps": maps,
            "bytes": size_bytes,
        }
        print(f"  {tid:16s} {size_bytes / 1024:7.1f} KB")
    out["bytes"] = total
    with open(os.path.join(args.out, "textures.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1, sort_keys=True)
    print(f"textures: {len(out['textures'])} textures, {total / 1024 / 1024:.2f} MB -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
