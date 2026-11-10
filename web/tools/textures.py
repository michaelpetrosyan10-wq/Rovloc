#!/usr/bin/env python3
"""Packs the generated PBR textures (tools/textures) into WebP maps for the web build, one set per graphics tier.

    python3 tools/textures.py [--tiers 2048,1024,512,256] [--quality 85] [--out build/textures]

Every variant texture of tools/textures/manifest.json is written at four sizes, the texture sets the graphics tiers
stream (web/src/engine/textures.js; quality.js textureSize):

    <size>/<Id>_color.webp    sRGB albedo (RGB, lossy), multiplied in the shader by the part colour (already divided
                              by the texture's reference albedo by Palette.colorFor, exactly like Roblox's
                              MaterialVariant). Every size.
    <size>/<Id>_normal.webp   tangent-space normal, lossless (R = x, G = y in the OpenGL convention: +Y up, three.js's
                              default; B is stored as 1.0: the maps are gentle, so z ~ 1 and the shader's normalize()
                              after the perturbation absorbs it). Lossy WebP subsamples chroma, which flattened the
                              subtle maps. 2048 and 1024 only (Max, High, Medium draw normal maps).
    <size>/<Id>_orm.webp      lossless, R = 1 (no AO), G = roughness, B = metalness (0 without a metalness map):
                              three.js's ORM layout, at half the size. 2048 and 1024 only.

    2048  Max            colour 2048, normal 2048, orm 1024   from tools/textures/out/2048 (generate.py --size 2048:
                                                              the same textures with the detail 1024 cannot hold)
    1024  High, Medium   colour 1024, normal 1024, orm 512    from tools/textures/out (the 1024 masters Roblox uses)
    512   Low            colour 512                           downsampled from the masters
    256   Potato         colour 256                           downsampled: what a school Chromebook downloads

plus textures.json: { textures: { <Id>: { studsPerTile, reference, pattern, hasMetalness, maps (the 1024 set), tiers:
{ <size>: { maps, bytes } }, bytes } }, bytes, settings }. Missing sources are generated first (generate.py).
Overlay textures (WallGrime, FloorDirt, ...) are not used by the game and are skipped. Deterministic: the same inputs
give the same files (WebP encoding is deterministic for fixed settings), and maps newer than their sources, this
script and the same settings are reused.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.dirname(HERE)
ROOT = os.path.dirname(WEB)
GEN = os.path.join(ROOT, "tools", "textures")
MANIFEST = os.path.join(GEN, "manifest.json")
SOURCE = os.path.join(GEN, "out")
TIERS = (2048, 1024, 512, 256)
# sizes that carry normal and roughness maps (the tiers that draw them)
RELIEF = {2048, 1024}


def source_dir(size: int, design: int) -> str:
    return os.path.join(SOURCE, str(size)) if size > design else SOURCE


def ensure_generated(manifest: dict, size: int) -> None:
    design = manifest["size"]
    out = source_dir(size, design)
    missing = []
    for m in manifest["materials"]:
        if m["kind"] != "variant":
            continue
        for kind in m["maps"]:
            if not os.path.exists(os.path.join(out, f"{m['id']}_{kind}.png")):
                missing.append(m["id"])
                break
    if missing:
        ids = ",".join(sorted(set(missing)))
        print(f"textures: generating {ids} at {max(size, design)}")
        cmd = [sys.executable, os.path.join(GEN, "generate.py"), "--only", ids, "--no-preview"]
        if size > design:
            cmd += ["--size", str(size), "--out", out]
        subprocess.run(cmd, check=True)


def load(path: str, mode: str, size: int) -> Image.Image:
    img = Image.open(path).convert(mode)
    if img.size != (size, size):
        img = img.resize((size, size), Image.Resampling.LANCZOS)
    return img


def write_set(m: dict, size: int, design: int, out_dir: str, quality: int) -> dict:
    """Writes one texture's maps at one tier size; returns {color, normal?, orm?} paths relative to build/."""
    tid = m["id"]
    src = source_dir(size, design)
    rel = f"textures/{size}"
    os.makedirs(os.path.join(out_dir, str(size)), exist_ok=True)
    maps = {}
    color = load(os.path.join(src, f"{tid}_ColorMap.png"), "RGB", size)
    name = f"{tid}_color.webp"
    color.save(os.path.join(out_dir, str(size), name), "WEBP", quality=quality, method=6)
    maps["color"] = f"{rel}/{name}"
    if size not in RELIEF:
        return maps
    if "NormalMap" in m["maps"]:
        normal = np.asarray(load(os.path.join(src, f"{tid}_NormalMap.png"), "RGB", size)).copy()
        normal[..., 2] = 255
        # strong maps lose nothing visible at 2-level steps (and compress far better); gentle ones keep every level
        if normal[..., :2].astype(float).std() > 6:
            normal[..., :2] = (np.round(normal[..., :2].astype(float) / 2) * 2).clip(0, 255).astype(np.uint8)
        name = f"{tid}_normal.webp"
        Image.fromarray(normal).save(os.path.join(out_dir, str(size), name), "WEBP", lossless=True, quality=100, method=6)
        maps["normal"] = f"{rel}/{name}"
    if "RoughnessMap" in m["maps"] or "MetalnessMap" in m["maps"]:
        osize = size // 2
        rough = (
            load(os.path.join(src, f"{tid}_RoughnessMap.png"), "L", osize)
            if "RoughnessMap" in m["maps"]
            else Image.new("L", (osize, osize), 180)
        )
        metal = (
            load(os.path.join(src, f"{tid}_MetalnessMap.png"), "L", osize)
            if "MetalnessMap" in m["maps"]
            else Image.new("L", (osize, osize), 0)
        )
        orm = np.stack([np.full((osize, osize), 255, np.uint8), np.asarray(rough), np.asarray(metal)], -1)
        orm[..., 1:] = (np.round(orm[..., 1:].astype(float) / 2) * 2).clip(0, 255).astype(np.uint8)
        name = f"{tid}_orm.webp"
        Image.fromarray(orm).save(os.path.join(out_dir, str(size), name), "WEBP", lossless=True, quality=100, method=6)
        maps["orm"] = f"{rel}/{name}"
    return maps


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tiers", default=",".join(str(t) for t in TIERS), help="texture set sizes to write")
    parser.add_argument("--quality", type=int, default=85, help="WebP quality for colour maps")
    parser.add_argument("--out", default=os.path.join(WEB, "build", "textures"))
    args = parser.parse_args()
    tiers = [int(t) for t in args.tiers.split(",") if t]

    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)
    design = manifest["size"]
    for size in sorted(set(max(t, design) for t in tiers)):
        ensure_generated(manifest, size)
    gen_meta = {}
    meta_path = os.path.join(SOURCE, "meta.json")
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as fh:
            gen_meta = json.load(fh)

    os.makedirs(args.out, exist_ok=True)
    settings = {"tiers": tiers, "quality": args.quality, "relief": sorted(RELIEF), "orm": "half"}
    previous = {}
    index_path = os.path.join(args.out, "textures.json")
    if os.path.exists(index_path):
        with open(index_path, encoding="utf-8") as fh:
            old = json.load(fh)
        if old.get("settings") == settings:
            previous = old.get("textures", {})
    out = {"textures": {}, "bytes": 0, "settings": settings}
    total = 0
    script_time = os.path.getmtime(os.path.abspath(__file__))
    for m in manifest["materials"]:
        if m["kind"] != "variant":
            continue
        tid = m["id"]
        entry = {
            "studsPerTile": m["studsPerTile"],
            "pattern": m.get("pattern"),
            "reference": gen_meta.get(tid, {}).get("reference"),
            "hasMetalness": "MetalnessMap" in m["maps"],
            "tiers": {},
        }
        line = []
        for size in tiers:
            cached = previous.get(tid, {}).get("tiers", {}).get(str(size))
            src = source_dir(size, design)
            sources = [os.path.join(src, f"{tid}_{k}.png") for k in m["maps"]]
            if cached:
                files = [os.path.join(WEB, "build", p) for p in cached["maps"].values()]
                if all(os.path.exists(f) for f in files):
                    newest = max([script_time] + [os.path.getmtime(f) for f in sources if os.path.exists(f)])
                    if min(os.path.getmtime(f) for f in files) > newest:
                        entry["tiers"][str(size)] = cached
                        line.append(f"{size}: {cached['bytes'] / 1024:.0f} KB (cached)")
                        continue
            maps = write_set(m, size, design, args.out, args.quality)
            size_bytes = sum(os.path.getsize(os.path.join(WEB, "build", p)) for p in maps.values())
            entry["tiers"][str(size)] = {"maps": maps, "bytes": size_bytes}
            line.append(f"{size}: {size_bytes / 1024:.0f} KB")
        entry["maps"] = (entry["tiers"].get("1024") or next(iter(entry["tiers"].values())))["maps"]
        entry["bytes"] = sum(t["bytes"] for t in entry["tiers"].values())
        total += entry["bytes"]
        out["textures"][tid] = entry
        print(f"  {tid:16s} " + ", ".join(line))
    out["bytes"] = total
    per_tier = {str(t): sum(e["tiers"][str(t)]["bytes"] for e in out["textures"].values()) for t in tiers}
    out["tierBytes"] = per_tier
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1, sort_keys=True)
    sizes = ", ".join(f"{t}: {per_tier[str(t)] / 1048576:.2f} MB" for t in tiers)
    print(f"textures: {len(out['textures'])} textures ({sizes}) -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
