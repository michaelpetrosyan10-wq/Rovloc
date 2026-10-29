"""The Rovloc surface recipes. Each takes a seeded texlib.Field and returns a Surface.

Colour maps are authored around a light, near-neutral base layer (`reference`) whose hue is close to the palette
colour of the surface's main key. In game the part's Color multiplies the colour map, so MaterialLibrary sets the
part colour to palette / reference: the base layer lands exactly on today's palette grading and every stain, chip,
grout line and rust patch keeps its relative darkness and hue on top of it.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from texlib import (
    F32,
    Field,
    lerp,
    mix,
    multiply,
    norm01,
    plank_grid,
    rgb,
    smoothstep,
    solid,
    tile_grid,
)


@dataclass
class Surface:
    color: np.ndarray  # (n, n, 3) 0..1 sRGB
    height: np.ndarray  # (n, n) pixels
    normal_strength: float
    roughness: np.ndarray | None = None  # (n, n) 0..1
    metalness: np.ndarray | None = None  # (n, n) 0..1
    alpha: np.ndarray | None = None  # (n, n) 0..1, overlays only
    reference: np.ndarray | None = None  # rgb of the base layer


def blotches(f: Field, coverage: float, softness: float = 0.08, fmin: float = 1, fmax: float = 40, beta=2.4):
    """Stain mask covering roughly `coverage` of the tile: soft-edged (softness ~0.05 crisp .. 0.3 very soft) and
    broken up by finer noise so no edge reads as a clean vector shape."""
    v = f.spectral(beta, fmin, fmax) + 0.35 * f.spectral(1.3, fmax * 0.5, fmax * 8)
    t = np.quantile(v, 1 - coverage)
    return smoothstep(t - softness * 4, t + softness * 4, v)


def tide(f: Field, mask: np.ndarray, width: float) -> np.ndarray:
    """The darker rim a dried water stain leaves at its edge (mask 0..1 -> rim 0..1)."""
    inner = f.blur(mask, width)
    return np.clip((mask - inner) * 3.0, 0, 1) * smoothstep(0.05, 0.5, mask)


def ring_field(f: Field, cx: float, cy: float) -> np.ndarray:
    """Toroidal distance (pixels) from (cx, cy)."""
    n = f.n
    dx = f.x - cx
    dy = f.y - cy
    dx -= n * np.round(dx / n)
    dy -= n * np.round(dy / n)
    return np.sqrt(dx * dx + dy * dy)


def cracks(f: Field, cells: int, keep: float, width: float, warp: float = 7.0):
    """A sparse, jagged crack network: warped Worley borders, only where a low-frequency mask allows."""
    f1, f2, _ = f.worley(cells, 0.95)
    border = f2 - f1
    wx = f.spectral(1.8, 3, 120) * warp
    wy = f.spectral(1.8, 3, 120) * warp
    border = f.warp(border, wx, wy)
    line = 1 - smoothstep(0, width, border)
    allow = smoothstep(1 - keep - 0.05, 1 - keep + 0.05, f.fbm01(2.2, 1, 12))
    return (line * allow).astype(F32)


# -- 1. Stained painted plaster ---------------------------------------------------------------------------------


def painted_plaster(f: Field) -> Surface:
    n = f.n
    ref = rgb(0.80, 0.77, 0.69)
    col = solid(n, ref)
    tone = f.spectral(2.6, 1, 30)
    col *= (1 + 0.045 * tone)[..., None]
    col = mix(col, rgb(0.84, 0.82, 0.76), 0.35 * blotches(f, 0.3, 0.2, 1, 10))  # patch repaints, a shade cooler

    # surface: trowelled plaster undulation, roller stipple, a few patched areas
    undulate = f.spectral(3.0, 2, 60)
    stipple = f.spectral(0.6, 120, 480)
    height = 1.8 * undulate + 0.16 * stipple
    rough = 0.62 + 0.05 * stipple

    # older paint layer + bare plaster under chipped and peeling paint
    peel_field = f.spectral(1.9, 3, 260) + 1.4 * f.spectral(2.8, 1, 10)
    peel = smoothstep(2.25, 2.33, peel_field)
    under = smoothstep(2.55, 2.62, peel_field)  # deepest chips reach the plaster
    old_paint = rgb(0.62, 0.70, 0.62)  # the institutional green from the decade before
    plaster = rgb(0.74, 0.72, 0.66)
    col = mix(col, old_paint, peel)
    col = mix(col, plaster * (0.9 + 0.1 * f.fbm01(1.0, 60, 400))[..., None], under)
    lip = np.clip(f.blur(peel, 2.5) - peel, 0, 1) * 2.5  # paint edge just outside each chip: dirt line
    col = multiply(col, rgb(0.62, 0.56, 0.46), np.clip(lip, 0, 0.5))
    height += 1.2 * (1 - peel) + 0.5 * (1 - under)  # paint film sits proud of what is under it
    flake = np.clip(f.blur(peel, 0.8) - f.blur(peel, 3.0), 0, 1)  # curled flake edges
    height += 2.5 * flake
    rough = lerp(rough, 0.86, under)

    # hairline cracks
    crack = cracks(f, 7, 0.4, 1.0, 9)
    col = multiply(col, rgb(0.45, 0.42, 0.38), 0.7 * crack)
    height -= 2.0 * crack

    # grime: broad dirty patches, darker toward the stain cores
    grime = blotches(f, 0.4, 0.25, 2, 18)
    col = multiply(col, rgb(0.82, 0.77, 0.66), 0.42 * grime)
    grime_core = blotches(f, 0.15, 0.15, 2, 30)
    col = multiply(col, rgb(0.70, 0.64, 0.53), 0.35 * grime_core * grime)

    # water runs: streaks that start somewhere on the wall and run down, tea-coloured with a darker tide edge
    runs = np.clip(f.drips(26, (160, 650), (1.8, 3.6), wobble=0.05, head=1.2), 0, 1)
    runs *= 0.5 + 0.5 * f.fbm01(1.6, 4, 120)  # runs break and thin out along their length
    halo = f.directional_blur(runs, 5, 2)
    streak = f.directional_blur(f.spectral(1.4, 2, 300, stretch=(1, 14)), 0.8, 2)
    streak = smoothstep(0.8, 2.6, streak)
    wet = np.clip(runs * 0.9 + halo * 1.4 + 0.45 * streak * grime, 0, 1)
    col = multiply(col, rgb(0.84, 0.76, 0.58), 0.6 * wet)
    col = multiply(col, rgb(0.66, 0.56, 0.42), 0.45 * runs)
    rough = lerp(rough, 0.52, 0.5 * wet)  # water-marked paint is a touch glossier

    # mildew: dark speckle clusters
    cluster = blotches(f, 0.08, 0.1, 3, 40)
    specks = smoothstep(2.0, 3.2, f.spectral(0.4, 150, 512))
    col = multiply(col, rgb(0.30, 0.34, 0.26), 0.8 * specks * cluster)

    # fine dust and fingerprints of decades
    col *= (1 - 0.05 * f.fbm01(1.2, 40, 300))[..., None]
    return Surface(np.clip(col, 0, 1), height, 0.55, np.clip(rough, 0, 1), reference=ref)


# -- 2. Black and white checker ceramic floor -------------------------------------------------------------------


def checker_tile(f: Field) -> Surface:
    n = f.n
    cols = rows = 4
    g = tile_grid(n, cols, rows)
    half = 3.4  # grout half width (pixels)
    d = g.edge - half
    tile = smoothstep(-0.6, 0.8, d)
    parity = ((g.id // cols + g.id % cols) % 2).astype(F32)
    rnd = f.rng.random((g.count, 4)).astype(F32)
    white = rgb(0.86, 0.85, 0.81)
    black = rgb(0.075, 0.075, 0.08)

    shade = 1 + 0.05 * (g.per_tile(rnd[:, 0]) - 0.5)
    yellow = g.per_tile(rnd[:, 1])
    w = solid(n, white) * shade[..., None]
    w = multiply(w, rgb(0.97, 0.93, 0.84), 0.5 * yellow)
    b = solid(n, black) * (1 + 0.25 * (g.per_tile(rnd[:, 2]) - 0.5))[..., None]
    glaze = f.spectral(2.2, 2, 60)
    w *= (1 + 0.025 * glaze)[..., None]
    b *= (1 + 0.08 * glaze)[..., None]
    col = mix(w, b, parity)

    # grout and the dirt that packs into it and against tile edges
    grout = rgb(0.30, 0.27, 0.23) * (0.85 + 0.3 * f.fbm01(1.0, 40, 400))[..., None]
    col = mix(grout, col, tile)
    near = np.exp(-np.clip(d, 0, None) / 7.0) * tile
    dirt_var = f.fbm01(1.6, 6, 200)
    col = multiply(col, rgb(0.62, 0.55, 0.45), 0.55 * near * dirt_var * (1 - parity))
    col = mix(col, rgb(0.20, 0.18, 0.15), 0.3 * near * dirt_var * parity)

    # traffic dirt: a broad grey-brown haze, worse in patches
    haze = blotches(f, 0.45, 0.25, 1, 12)
    col = multiply(col, rgb(0.82, 0.78, 0.70), 0.45 * haze)
    col = mix(col, rgb(0.35, 0.32, 0.28), 0.12 * haze * parity)  # dust greys the black tiles

    # heel scuffs: short dark curved marks, mostly on the pale tiles; and grey scuffs on the black
    scuff = f.strokes(55, (6, 28), (3.0, 6.0), wobble=0.1, intensity=(0.1, 0.45))  # rubber heel smudges
    scuff = np.clip(f.blur(scuff, 2.0) * 1.4, 0, 1)
    col = mix(col, rgb(0.16, 0.15, 0.14), 0.5 * scuff * (1 - parity) * tile)
    scuff_g = f.strokes(70, (20, 90), (1.0, 2.6), wobble=0.04, intensity=(0.2, 0.7))
    col = mix(col, rgb(0.42, 0.42, 0.40), np.clip(scuff_g, 0, 1) * parity * tile * 0.6)

    # a few cracked tiles and chipped corners showing the biscuit
    crack = np.clip(f.strokes(4, (150, 320), (0.8, 1.2), wobble=0.1, intensity=(0.7, 1.0), taper=False), 0, 1)
    col = multiply(col, rgb(0.25, 0.23, 0.20), 0.9 * crack * tile)
    chip_n = 14
    cx = (f.rng.integers(0, cols + 1, chip_n) * (n / cols) + f.rng.normal(0, 4, chip_n)) % n
    cy = (f.rng.integers(0, rows + 1, chip_n) * (n / rows) + f.rng.normal(0, 4, chip_n)) % n
    chips = np.zeros((n, n), F32)
    for i in range(chip_n):
        r = f.rng.uniform(5, 13)
        chips = np.maximum(chips, 1 - smoothstep(r * 0.7, r, ring_field(f, cx[i], cy[i])))
    chips *= tile * smoothstep(0.3, 0.6, f.fbm01(0.8, 40, 300))
    col = mix(col, rgb(0.62, 0.58, 0.50), chips)

    # height: bevelled tiles, recessed grout, slight lippage between tiles, crazing barely there
    bevel = smoothstep(-0.5, 6.0, d)
    tilt = (g.per_tile(rnd[:, 3]) - 0.5) * 1.2
    height = 3.0 * bevel + tilt * (g.u - 0.5) * tile + 0.15 * glaze * tile
    height -= 2.0 * crack + 2.5 * chips
    height += 0.4 * f.spectral(0.8, 100, 400) * (1 - tile)  # sandy grout

    rough = np.where(parity > 0.5, 0.14, 0.18).astype(F32) + 0.06 * f.fbm01(1.5, 4, 100)
    rough = lerp(rough, 0.5, 0.6 * haze)
    rough = lerp(rough, 0.55, scuff)
    rough = lerp(rough, 0.92, 1 - tile)
    rough = lerp(rough, 0.85, chips)
    return Surface(np.clip(col, 0, 1), height, 0.6, np.clip(rough, 0, 1), reference=white)


# -- 3. Cracked, stained concrete -------------------------------------------------------------------------------


def stained_concrete(f: Field) -> Surface:
    n = f.n
    ref = rgb(0.60, 0.59, 0.56)
    col = solid(n, ref)
    col *= (1 + 0.07 * f.spectral(2.2, 1, 50))[..., None]
    col *= (1 + 0.035 * f.spectral(1.0, 30, 300))[..., None]

    # exposed aggregate and sand
    f1, _, val = f.worley(70, 1.0)
    agg = smoothstep(6.0, 3.0, f1) * (val - 0.5)
    expose = smoothstep(0.35, 0.8, f.fbm01(2.0, 2, 30))
    col *= (1 + 0.16 * agg * expose)[..., None]
    grain = f.spectral(0.3, 200, 512)
    col *= (1 + 0.04 * grain)[..., None]

    # bug holes / pores
    k = 2600
    px, py = f.rng.uniform(0, n, k), f.rng.uniform(0, n, k)
    pores = np.clip(f.splat(px, py, f.rng.uniform(0.4, 1.0, k), 2.5, 1.1), 0, 1)
    col = multiply(col, rgb(0.42, 0.41, 0.39), 0.8 * pores)

    # cracks: a couple of long ones with branches, plus shrinkage hairlines
    main = f.strokes(3, (350, 800), (1.2, 2.0), wobble=0.09, intensity=(0.8, 1.0), taper=True)
    branch = f.strokes(12, (30, 160), (0.8, 1.3), wobble=0.16, intensity=(0.5, 0.9))
    hair = cracks(f, 10, 0.3, 0.8, 6)
    crack = np.clip(main * 1.2 + branch * 0.9, 0, 1)
    spall = np.clip(f.blur(crack, 3.0) * 2.2 - crack, 0, 1)
    col = mix(col, rgb(0.70, 0.69, 0.66), 0.2 * spall)
    col = multiply(col, rgb(0.30, 0.29, 0.27), 0.8 * crack)
    col = multiply(col, rgb(0.55, 0.54, 0.52), 0.5 * hair)

    # stains: water and oil blotches with tide rims, efflorescence, rust bleed
    water = blotches(f, 0.32, 0.2, 2, 24)
    rim = tide(f, water, 6)
    col = multiply(col, rgb(0.74, 0.72, 0.66), 0.6 * water)
    col = multiply(col, rgb(0.64, 0.60, 0.54), 0.5 * rim)
    oil = blotches(f, 0.07, 0.12, 2, 40)
    col = multiply(col, rgb(0.42, 0.40, 0.36), 0.75 * oil)
    eff = blotches(f, 0.12, 0.15, 2, 40) * f.fbm01(1.0, 30, 300)
    col = mix(col, rgb(0.86, 0.85, 0.80), 0.45 * eff)
    rust = np.clip(f.drips(5, (200, 500), (2.5, 4.5), wobble=0.05), 0, 1)
    rust = f.directional_blur(rust, 3, 1) * 1.5
    col = multiply(col, rgb(0.82, 0.66, 0.50), np.clip(rust, 0, 0.6))
    col *= (1 - 0.06 * f.fbm01(1.3, 50, 400))[..., None]

    height = 2.0 * f.spectral(2.6, 2, 80) + 0.35 * grain + 0.5 * agg * expose
    height -= 2.2 * pores + 3.5 * crack + 1.2 * hair
    height += 0.6 * eff

    rough = 0.86 + 0.06 * f.fbm01(1.2, 10, 200)
    rough = lerp(rough, 0.55, 0.6 * water)  # damp patches pick up the light
    rough = lerp(rough, 0.45, oil)
    rough = lerp(rough, 0.97, eff)
    return Surface(np.clip(col, 0, 1), height, 0.5, np.clip(rough, 0, 1), reference=ref)


# -- 4. Acoustic drop-ceiling tiles -----------------------------------------------------------------------------


def ceiling_tile(f: Field) -> Surface:
    n = f.n
    cols, rows = 2, 4  # 4 x 2 stud tiles on an 8-stud repeat
    g = tile_grid(n, cols, rows)
    half = 4.0
    d = g.edge - half
    tile = smoothstep(-0.5, 1.0, d)
    rnd = f.rng.random((g.count, 4)).astype(F32)
    ref = rgb(0.84, 0.82, 0.76)
    col = solid(n, ref)
    # per-tile age: some yellowed, one replaced (whiter)
    col = multiply(col, rgb(0.94, 0.90, 0.78), 0.6 * g.per_tile(rnd[:, 0]) ** 2)
    col *= (1 + 0.04 * f.spectral(2.0, 2, 40))[..., None]

    # fissured acoustic surface: worm-like fissures and pinholes
    ridge = 1 - np.abs(f.spectral(1.6, 40, 160))
    fis = smoothstep(0.93, 0.985, ridge) * smoothstep(0.2, 0.6, f.fbm01(1.2, 30, 200))
    k = 9000
    pin = np.clip(f.splat(f.rng.uniform(0, n, k), f.rng.uniform(0, n, k), f.rng.uniform(0.5, 1, k), 1.6, 0.7), 0, 1)
    col = multiply(col, rgb(0.55, 0.53, 0.48), 0.7 * fis * tile)
    col = multiply(col, rgb(0.50, 0.48, 0.44), 0.6 * pin * tile)
    col *= (1 + 0.05 * f.spectral(0.5, 200, 512))[..., None]

    # water stains: concentric tide rings on a few tiles, brown and darker at each rim
    stains = np.zeros((n, n), F32)
    rims = np.zeros((n, n), F32)
    wobble = f.spectral(2.2, 2, 24)
    for _ in range(2):
        cx, cy = f.rng.uniform(0, n), f.rng.uniform(0, n)
        r0 = f.rng.uniform(70, 160)
        dist = ring_field(f, cx, cy) * (1 + 0.16 * wobble)
        for j, scale in enumerate((1.0, 0.8, 0.62, 0.4)):
            inside = smoothstep(r0 * scale + 3, r0 * scale - 8, dist)
            stains = np.maximum(stains, inside * (0.35 + 0.15 * j))
            rims = np.maximum(rims, np.exp(-(((dist - r0 * scale) / 2.2) ** 2)) * (0.9 - 0.18 * j))
    col = multiply(col, rgb(0.90, 0.82, 0.64), 0.7 * stains * tile)
    col = multiply(col, rgb(0.66, 0.52, 0.34), 0.55 * rims * tile)
    mildew = blotches(f, 0.06, 0.1, 3, 40) * smoothstep(2.0, 3.0, f.spectral(0.5, 120, 500))
    col = multiply(col, rgb(0.30, 0.30, 0.24), 0.7 * mildew * tile)

    # T-bar grid: off-white painted steel, a little dirtier along its edges
    bar = rgb(0.86, 0.85, 0.82) * (0.92 + 0.08 * f.fbm01(1.0, 20, 300))[..., None]
    bar = multiply(bar, rgb(0.62, 0.58, 0.52), 0.6 * blotches(f, 0.3, 0.2, 2, 30))
    col = mix(bar, col, tile)
    shadow = np.exp(-np.clip(d, 0, None) / 4.0) * tile  # tile edge tucked under the flange
    col *= (1 - 0.25 * shadow)[..., None]

    # height: flanges proud, tiles sag a little, fissures and pins sunken
    sag = np.sin(np.pi * g.u) * np.sin(np.pi * g.v) * (0.5 + 2.5 * g.per_tile(rnd[:, 1]))
    height = 4.0 * (1 - tile) - sag * tile - 1.4 * fis - 1.0 * pin + 0.3 * f.spectral(1.0, 60, 400) * tile
    height += 1.2 * smoothstep(0, 6, d) * tile  # tile face edge (reveal)
    rough = lerp(np.full((n, n), 0.95, F32), 0.42, 1 - tile)
    return Surface(np.clip(col, 0, 1), height, 0.45, np.clip(rough, 0, 1), reference=ref)


# -- 5. Rusted painted metal ------------------------------------------------------------------------------------


def rusted_metal(f: Field) -> Surface:
    n = f.n
    ref = rgb(0.74, 0.74, 0.72)
    col = solid(n, ref)
    col *= (1 + 0.04 * f.spectral(2.2, 1, 30))[..., None]
    peel = f.spectral(0.5, 80, 500)  # orange-peel paint texture
    col *= (1 + 0.012 * peel)[..., None]

    # paint failure: clusters of chips exposing rust, with bright bare steel rims at fresh chips
    cluster = f.spectral(2.4, 1, 14)
    chip_field = f.spectral(1.9, 4, 200) + 0.35 * f.spectral(1.0, 60, 400) + 0.45 * cluster
    chip = smoothstep(1.85, 1.95, chip_field)
    fresh = np.clip(f.blur(chip, 1.2) * 2.5 - chip * 2.5, 0, 1) * smoothstep(0.4, 0.7, f.fbm01(1.4, 10, 200))
    rust_tone = f.fbm01(1.5, 8, 300)
    rust = lerp(rgb(0.30, 0.17, 0.10), rgb(0.60, 0.34, 0.16), rust_tone[..., None])
    rust *= (0.8 + 0.4 * f.fbm01(0.4, 150, 512))[..., None]
    halo = np.clip(f.blur(chip, 7) * 2.0 - chip, 0, 1)  # rust creeping under the paint: blistered, brownish
    col = multiply(col, rgb(0.80, 0.64, 0.48), 0.6 * halo)
    col = mix(col, rust, chip)
    steel = rgb(0.62, 0.62, 0.64)
    col = mix(col, steel, 0.8 * fresh * (1 - chip))

    # rust runs from the chips down the panel
    ys, xs = np.nonzero(chip[::8, ::8] > 0.5)
    pick = f.rng.permutation(len(xs))[:60] if len(xs) else np.array([], int)
    runs = f.drips(0, (60, 320), (1.6, 3.2), wobble=0.04, sources=(xs[pick] * 8.0, ys[pick] * 8.0)) if len(pick) else 0
    runs = np.clip(runs, 0, 1)
    runs = np.clip(runs * 0.6 + f.directional_blur(runs, 3, 1) * 0.9, 0, 1)
    col = multiply(col, rgb(0.74, 0.56, 0.40), 0.65 * runs * (1 - chip))

    # scratches through the paint to bright steel
    scr = np.clip(f.strokes(45, (15, 110), (0.7, 1.1), angle=(-0.5, 0.5), wobble=0.01, intensity=(0.2, 0.7)), 0, 1)
    col = mix(col, steel * 1.1, 0.6 * scr * (1 - chip))

    # grime and handling marks
    grime = blotches(f, 0.35, 0.2, 1, 16)
    col = multiply(col, rgb(0.72, 0.68, 0.60), 0.5 * grime)

    height = 4.0 * f.spectral(3.0, 1, 12)  # dents and warping
    height += 0.08 * peel + 1.6 * (1 - chip) + 1.2 * halo * (1 - chip)  # paint film, blisters
    height += 0.9 * f.spectral(0.8, 60, 400) * chip  # pitted rust
    height -= 0.8 * scr

    metal = np.clip(fresh * (1 - chip) * 0.95 + scr * (1 - chip), 0, 1)
    rough = 0.40 + 0.06 * f.fbm01(1.4, 6, 200)
    rough = lerp(rough, 0.6, grime * 0.6)
    rough = lerp(rough, 0.55, runs)
    rough = lerp(rough, 0.92, chip)
    rough = lerp(rough, 0.30, metal)
    return Surface(np.clip(col, 0, 1), height, 0.6, np.clip(rough, 0, 1), np.clip(metal, 0, 1), reference=ref)


# -- 6. Galvanised duct steel -----------------------------------------------------------------------------------


def galvanized_metal(f: Field) -> Surface:
    n = f.n
    ref = rgb(0.68, 0.69, 0.70)
    f1, f2, val = f.worley(16, 1.0)
    spangle = (val - 0.5) * 0.16
    facet = np.clip((f2 - f1) / 30.0, 0, 1)
    col = solid(n, ref) * (1 + spangle + 0.02 * facet)[..., None]
    col *= (1 + 0.03 * f.spectral(2.0, 1, 30))[..., None]
    oxide = blotches(f, 0.2, 0.2, 2, 30) * f.fbm01(1.0, 20, 300)
    col = mix(col, rgb(0.80, 0.80, 0.78), 0.35 * oxide)  # white rust
    dust = blotches(f, 0.45, 0.3, 1, 10) * (0.6 + 0.4 * f.fbm01(0.5, 100, 500))
    col = mix(col, rgb(0.64, 0.62, 0.58), 0.3 * dust)
    stain = blotches(f, 0.1, 0.15, 2, 40)
    col = multiply(col, rgb(0.62, 0.60, 0.56), 0.4 * stain)
    runs = np.clip(f.drips(18, (80, 400), (3, 7), wobble=0.08), 0, 1)
    col = multiply(col, rgb(0.78, 0.62, 0.46), 0.6 * runs)
    scr = np.clip(f.strokes(80, (30, 160), (0.7, 1.2), angle=(-0.3, 0.3), intensity=(0.3, 0.8)), 0, 1)
    col = mix(col, rgb(0.82, 0.83, 0.85), 0.5 * scr)
    height = 2.0 * f.spectral(3.2, 1, 10) + 0.25 * facet + 0.6 * oxide - 0.5 * scr
    metal = np.clip(0.95 - 0.45 * dust - 0.4 * oxide - 0.4 * stain - 0.4 * runs, 0, 1)
    rough = 0.38 + 0.14 * (val - 0.5) + 0.22 * dust + 0.25 * oxide + 0.15 * stain
    return Surface(np.clip(col, 0, 1), height, 0.45, np.clip(rough, 0, 1), metal, reference=ref)


# -- 7. Worn wood boards ----------------------------------------------------------------------------------------


def worn_wood(f: Field) -> Surface:
    n = f.n
    g = plank_grid(n, 14, f.rng, (260, 760))
    rnd = f.rng.random((g.count, 6)).astype(F32)
    ref = rgb(0.76, 0.58, 0.39)
    tone = 0.82 + 0.3 * g.per_tile(rnd[:, 0])
    hue = g.per_tile(rnd[:, 1])
    base = solid(n, ref) * tone[..., None]
    base = multiply(base, rgb(0.92, 0.84, 0.80), 0.5 * hue)  # some boards redder, some greyer

    # grain: long fibres along x, sampled with a per-board offset so neighbours differ
    fibres = f.spectral(1.2, 2, 500, stretch=(18, 1))
    rings = f.spectral(2.0, 1, 60, stretch=(10, 1))
    ox = g.per_tile(rnd[:, 2]) * n
    oy = g.per_tile(rnd[:, 3]) * n
    fib = f.warp(fibres, ox, oy)
    rng_ = f.warp(rings, ox, oy)
    figure = np.sin(rng_ * 9.0 + fib * 0.6)
    col = base * (1 + 0.07 * fib + 0.09 * figure)[..., None]
    knots = np.zeros((n, n), F32)
    for _ in range(7):
        cx, cy = f.rng.uniform(0, n), f.rng.uniform(0, n)
        dist = ring_field(f, cx, cy)
        knots = np.maximum(knots, np.exp(-((dist / f.rng.uniform(5, 10)) ** 2)))
    col = multiply(col, rgb(0.45, 0.32, 0.22), 0.8 * knots)

    # joints, dirt in the joints, worn finish in traffic lanes, water damage, scratches
    gap = 1 - smoothstep(0.6, 2.0, g.edge)
    col = mix(col, rgb(0.10, 0.07, 0.05), 0.9 * gap)
    near = np.exp(-g.edge / 5.0)
    col = multiply(col, rgb(0.70, 0.60, 0.50), 0.5 * near)
    wear = blotches(f, 0.4, 0.3, 1, 10) * f.fbm01(1.0, 30, 400)
    col = mix(col, col * 0.85 + rgb(0.68, 0.62, 0.54) * 0.15, wear)
    col = mix(col, rgb(0.66, 0.60, 0.52), 0.25 * wear)  # varnish gone: greyed, bleached wood
    water = blotches(f, 0.1, 0.12, 2, 30)
    col = multiply(col, rgb(0.72, 0.62, 0.52), 0.5 * water)
    col = multiply(col, rgb(0.55, 0.45, 0.36), 0.45 * tide(f, water, 5))
    scr = np.clip(f.strokes(160, (15, 120), (0.7, 1.3), angle=(-0.35, 0.35), intensity=(0.3, 0.9)), 0, 1)
    col = mix(col, col * 1.18, scr)
    dirt = blotches(f, 0.3, 0.2, 1, 20)
    col = multiply(col, rgb(0.72, 0.66, 0.58), 0.4 * dirt)

    tilt = (g.per_tile(rnd[:, 4]) - 0.5) * 1.5
    cup = (1 - (2 * g.v - 1) ** 2) * g.per_tile(rnd[:, 5]) * 1.2 * (0.4 + water)
    height = 2.2 * smoothstep(0.5, 4.0, g.edge) + tilt * (g.u - 0.5) - cup + 0.3 * fib + 0.2 * figure - 0.5 * scr
    rough = 0.34 + 0.05 * f.fbm01(1.5, 8, 200)
    rough = lerp(rough, 0.72, wear)
    rough = lerp(rough, 0.8, water * 0.7)
    rough = lerp(rough, 0.6, scr * 0.6)
    rough = lerp(rough, 0.95, gap)
    return Surface(np.clip(col, 0, 1), height, 0.5, np.clip(rough, 0, 1), reference=ref)


# -- 8. Pool mosaic ---------------------------------------------------------------------------------------------


def pool_mosaic(f: Field) -> Surface:
    n = f.n
    g = tile_grid(n, 16, 16)
    half = 2.4
    d = g.edge - half
    tile = smoothstep(-0.5, 0.7, d)
    rnd = f.rng.random((g.count, 5)).astype(F32)
    ref = rgb(0.84, 0.88, 0.87)
    tone = 0.9 + 0.2 * g.per_tile(rnd[:, 0])
    col = solid(n, ref) * tone[..., None]
    accent = (g.per_tile(rnd[:, 1]) > 0.86).astype(F32)
    col = multiply(col, rgb(0.82, 0.90, 0.94), accent * 0.8)  # mixed-blend mosaic: a few bluer chips
    col = multiply(col, rgb(0.94, 0.95, 0.90), (g.per_tile(rnd[:, 2]) > 0.8) * 0.8)
    col *= (1 + 0.03 * f.spectral(2.0, 4, 100))[..., None]
    missing = (g.id == int(f.rng.integers(0, g.count))).astype(F32)  # one chip gone

    grout = rgb(0.56, 0.57, 0.53) * (0.85 + 0.3 * f.fbm01(1.0, 40, 400))[..., None]
    algae_mask = blotches(f, 0.4, 0.25, 1, 16)
    grout = multiply(grout, rgb(0.36, 0.44, 0.34), 0.8 * algae_mask)
    col = mix(grout, col, tile * (1 - missing))
    mortar = rgb(0.52, 0.51, 0.47) * (0.8 + 0.4 * f.fbm01(0.5, 80, 500))[..., None]
    col = mix(col, mortar, missing * tile)
    near = np.exp(-np.clip(d, 0, None) / 4.0) * tile
    col = multiply(col, rgb(0.70, 0.76, 0.66), 0.5 * near * algae_mask)

    calcium = blotches(f, 0.15, 0.15, 2, 30) * f.fbm01(0.8, 40, 400)
    col = mix(col, rgb(0.90, 0.90, 0.86), 0.55 * calcium)
    scum = blotches(f, 0.35, 0.3, 1, 12)
    col = multiply(col, rgb(0.82, 0.84, 0.76), 0.45 * scum)
    rust = np.clip(f.drips(6, (100, 400), (4, 8), wobble=0.08), 0, 1)
    col = multiply(col, rgb(0.78, 0.58, 0.40), 0.7 * rust)

    dome = np.sin(np.pi * g.u) * np.sin(np.pi * g.v)
    height = (2.2 * smoothstep(-0.5, 3.0, d) + 0.6 * dome) * (1 - missing)
    height += (-2.5 + 0.8 * f.spectral(0.8, 80, 400)) * missing * tile
    height += 0.6 * calcium * f.fbm01(0.5, 100, 500)
    rough = np.full((n, n), 0.12, F32) + 0.05 * f.fbm01(1.4, 8, 200)
    rough = lerp(rough, 0.45, scum * 0.6)
    rough = lerp(rough, 0.88, 1 - tile)
    rough = lerp(rough, 0.9, np.maximum(missing * tile, calcium * 0.8))
    return Surface(np.clip(col, 0, 1), height, 0.55, np.clip(rough, 0, 1), reference=ref)


# -- 9. Stained brick -------------------------------------------------------------------------------------------


def stained_brick(f: Field) -> Surface:
    n = f.n
    g = tile_grid(n, 8, 32, row_shift=0.5)
    rnd = f.rng.random((g.count, 6)).astype(F32)
    edge_noise = 1.2 * f.spectral(1.2, 20, 300)
    half = 2.6
    d = g.edge - half + edge_noise
    brick = smoothstep(-0.4, 0.8, d)
    ref = rgb(0.62, 0.38, 0.29)
    tone = 0.78 + 0.38 * g.per_tile(rnd[:, 0])
    col = solid(n, ref) * tone[..., None]
    col = multiply(col, rgb(0.92, 1.0, 1.08), g.per_tile(rnd[:, 1]) * 0.6)  # cooler, browner bricks
    flashed = (g.per_tile(rnd[:, 2]) > 0.85).astype(F32)
    col = multiply(col, rgb(0.62, 0.55, 0.52), flashed * 0.8)
    col *= (1 + 0.08 * f.spectral(1.6, 10, 300) + 0.05 * f.spectral(0.4, 150, 512))[..., None]
    spalled = (g.per_tile(rnd[:, 3]) > 0.95).astype(F32) * smoothstep(0.3, 0.6, f.fbm01(1.5, 8, 100))
    col = mix(col, rgb(0.72, 0.47, 0.36) * (0.85 + 0.3 * f.fbm01(0.6, 60, 400))[..., None], spalled * brick)

    mortar = rgb(0.58, 0.56, 0.51) * (0.8 + 0.35 * f.fbm01(0.6, 60, 500))[..., None]
    col = mix(mortar, col, brick)
    eff = blotches(f, 0.22, 0.2, 1, 20) * f.fbm01(1.0, 30, 400)
    col = mix(col, rgb(0.86, 0.85, 0.81), 0.5 * eff * (0.6 + 0.4 * (1 - brick)))
    soot = f.directional_blur(f.spectral(1.6, 2, 200, stretch=(1, 10)), 0.6, 3)
    soot = smoothstep(1.0, 2.6, soot) * blotches(f, 0.5, 0.3, 1, 8)
    runs = np.clip(f.drips(16, (150, 600), (2.5, 5), wobble=0.04), 0, 1)
    runs = f.directional_blur(runs, 5, 1) * 1.6
    wet = np.clip(soot * 0.5 + runs, 0, 1)
    col = multiply(col, rgb(0.62, 0.57, 0.52), 0.6 * wet)
    grime = blotches(f, 0.3, 0.25, 1, 12)
    col = multiply(col, rgb(0.72, 0.68, 0.62), 0.5 * grime)

    pits = f.spectral(0.6, 80, 400)
    height = (3.0 * smoothstep(-0.5, 3.5, d) + 0.35 * pits) * brick + 0.4 * f.spectral(0.5, 100, 500) * (1 - brick)
    height -= 2.2 * spalled * brick * (1 + 0.4 * f.spectral(0.8, 40, 300))
    rough = lerp(np.full((n, n), 0.86, F32), 0.95, 1 - brick)
    rough = lerp(rough, 0.6, wet * 0.6)
    rough = lerp(rough, 0.97, eff)
    return Surface(np.clip(col, 0, 1), height, 0.55, np.clip(rough, 0, 1), reference=ref)


# -- 10. Classroom vinyl composition tile -----------------------------------------------------------------------


def vinyl_tile(f: Field) -> Surface:
    n = f.n
    g = tile_grid(n, 8, 8)
    rnd = f.rng.random((g.count, 4)).astype(F32)
    ref = rgb(0.80, 0.78, 0.70)
    parity = ((g.id // 8 + g.id % 8) % 2).astype(F32)
    tone = 1 - 0.07 * parity + 0.04 * (g.per_tile(rnd[:, 0]) - 0.5)
    col = solid(n, ref) * tone[..., None]
    # directional marbling of VCT, the run turned 90 degrees on alternate tiles
    mx = f.spectral(1.4, 3, 300, stretch=(1, 9))
    my = f.spectral(1.4, 3, 300, stretch=(9, 1))
    marble = np.where(parity > 0.5, mx, my)
    col *= (1 + 0.035 * marble)[..., None]
    f1, _, val = f.worley(150, 1.0)
    chip = smoothstep(3.2, 2.2, f1)
    col = mix(col, np.where(val[..., None] > 0.5, rgb(0.92, 0.90, 0.84), rgb(0.48, 0.45, 0.40)), 0.55 * chip)
    seam = 1 - smoothstep(0.4, 1.6, g.edge)
    col = multiply(col, rgb(0.35, 0.32, 0.28), 0.8 * seam)
    near = np.exp(-g.edge / 6.0)
    wax = blotches(f, 0.4, 0.25, 1, 16)
    col = multiply(col, rgb(0.90, 0.85, 0.70), 0.5 * near * (0.4 + 0.6 * wax))  # yellowed wax at the edges
    haze = blotches(f, 0.45, 0.3, 1, 12)
    col = multiply(col, rgb(0.84, 0.80, 0.72), 0.4 * haze)
    scuff = np.clip(f.strokes(130, (10, 60), (1.3, 3.0), wobble=0.07, intensity=(0.3, 1.0)), 0, 1)
    col = mix(col, rgb(0.12, 0.11, 0.10), 0.75 * scuff)
    grey = np.clip(f.strokes(80, (20, 100), (1.0, 2.0), wobble=0.03, intensity=(0.2, 0.6)), 0, 1)
    col = mix(col, rgb(0.55, 0.53, 0.50), 0.5 * grey)
    lift = (g.per_tile(rnd[:, 1]) > 0.93).astype(F32)
    corner = np.clip(1 - np.minimum(np.abs(g.u - g.per_tile(rnd[:, 2]).round()), 1) * 1.6, 0, 1)
    height = 0.6 * f.spectral(2.4, 1, 30) - 1.2 * seam + 0.2 * marble
    height += 2.0 * lift * corner * np.clip(1 - np.abs(g.v - g.per_tile(rnd[:, 3]).round()) * 1.6, 0, 1)
    rough = 0.28 + 0.06 * f.fbm01(1.5, 10, 200)
    rough = lerp(rough, 0.5, haze * 0.6)
    rough = lerp(rough, 0.62, np.maximum(scuff, grey * 0.6))
    rough = lerp(rough, 0.85, seam)
    return Surface(np.clip(col, 0, 1), height, 0.5, np.clip(rough, 0, 1), reference=ref)


# -- 11. Epoxy lab worktop --------------------------------------------------------------------------------------


def lab_worktop(f: Field) -> Surface:
    n = f.n
    ref = rgb(0.50, 0.50, 0.50)
    col = solid(n, ref) * (1 + 0.05 * f.spectral(2.0, 1, 40))[..., None]
    rings = np.zeros((n, n), F32)
    fill = np.zeros((n, n), F32)
    for _ in range(22):
        cx, cy = f.rng.uniform(0, n), f.rng.uniform(0, n)
        r = f.rng.uniform(14, 48)
        dist = ring_field(f, cx, cy) * (1 + 0.06 * f.spectral(1.8, 4, 40))
        rings = np.maximum(rings, np.exp(-(((dist - r) / f.rng.uniform(1.5, 3.5)) ** 2)) * f.rng.uniform(0.5, 1))
        fill = np.maximum(fill, smoothstep(r, r - 3, dist) * f.rng.uniform(0.1, 0.35))
    etch = blotches(f, 0.16, 0.12, 2, 40)
    etch_edge = tide(f, etch, 3)
    col = mix(col, rgb(0.85, 0.84, 0.80), np.clip(rings * 0.8 + fill + etch * 0.35 + etch_edge * 0.5, 0, 1))
    burn = blotches(f, 0.05, 0.08, 3, 50)
    col = multiply(col, rgb(0.40, 0.30, 0.22), 0.8 * burn)
    scr = np.clip(f.strokes(220, (20, 200), (0.6, 1.1), wobble=0.01, intensity=(0.2, 0.7)), 0, 1)
    col = mix(col, rgb(0.78, 0.78, 0.76), 0.55 * scr)
    dust = blotches(f, 0.4, 0.3, 1, 12) * f.fbm01(0.6, 80, 500)
    col = mix(col, rgb(0.66, 0.65, 0.62), 0.25 * dust)
    height = 0.4 * f.spectral(3.0, 1, 10) - 0.4 * scr - 0.5 * etch - 0.6 * rings
    rough = 0.16 + 0.05 * f.fbm01(1.5, 8, 200)
    rough = lerp(rough, 0.7, np.clip(rings + etch * 0.8 + fill, 0, 1))
    rough = lerp(rough, 0.45, scr)
    rough = lerp(rough, 0.8, dust * 0.5)
    rough = lerp(rough, 0.9, burn)
    return Surface(np.clip(col, 0, 1), height, 0.4, np.clip(rough, 0, 1), reference=ref)


# -- 12. Rubber matting -----------------------------------------------------------------------------------------


def rubber_mat(f: Field) -> Surface:
    n = f.n
    ref = rgb(0.50, 0.50, 0.50)
    f1, _, val = f.worley(110, 0.8)
    cell = n / 110
    bump = np.clip(1 - (f1 / (cell * 0.42)) ** 2, 0, 1) ** 0.5
    worn = blotches(f, 0.35, 0.25, 1, 10)
    col = solid(n, ref) * (1 + 0.06 * f.spectral(2.0, 1, 30) + 0.05 * (val - 0.5))[..., None]
    col *= (1 + 0.06 * bump * (1 - worn))[..., None]
    dust = blotches(f, 0.4, 0.3, 1, 12) * (0.5 + 0.5 * f.fbm01(0.5, 100, 500))
    col = mix(col, rgb(0.78, 0.76, 0.72), 0.45 * dust * (1 - bump * 0.5))
    scuff = np.clip(f.strokes(90, (20, 140), (1.5, 4.0), wobble=0.05, intensity=(0.2, 0.7)), 0, 1)
    col = mix(col, rgb(0.66, 0.65, 0.63), 0.5 * scuff)
    cut = np.clip(f.strokes(30, (10, 50), (0.8, 1.3), wobble=0.01, intensity=(0.6, 1.0)), 0, 1)
    col = multiply(col, rgb(0.3, 0.3, 0.3), 0.8 * cut)
    stain = blotches(f, 0.12, 0.12, 2, 30)
    col = multiply(col, rgb(0.60, 0.56, 0.52), 0.6 * stain)
    height = 2.2 * bump * (1 - 0.7 * worn) + 0.5 * f.spectral(2.6, 1, 20) - 1.5 * cut
    rough = 0.86 - 0.18 * worn + 0.1 * dust - 0.15 * stain
    return Surface(np.clip(col, 0, 1), height, 0.5, np.clip(rough, 0, 1), reference=ref)


# -- 13. Roof gravel over tar -----------------------------------------------------------------------------------


def roof_gravel(f: Field) -> Surface:
    n = f.n
    ref = rgb(0.56, 0.55, 0.52)
    layers = []
    for cells, rad in ((46, 0.62), (64, 0.55), (90, 0.5)):
        f1, _, val = f.worley(cells, 1.0)
        r = (n / cells) * rad * (0.8 + 0.4 * val)
        h = np.clip(1 - (f1 / r) ** 2, 0, 1) ** 0.6 * r * 0.5
        layers.append((h, val))
    height = np.zeros((n, n), F32)
    stone_val = np.zeros((n, n), F32)
    for h, val in layers:
        top = h > height
        stone_val = np.where(top, val, stone_val)
        height = np.maximum(height, h)
    stone = smoothstep(0.3, 1.2, height)
    grey = lerp(rgb(0.38, 0.37, 0.35), rgb(0.74, 0.72, 0.68), stone_val[..., None])
    grey = multiply(grey, rgb(1.0, 0.9, 0.78), (np.modf(stone_val * 7.31)[0] > 0.7).astype(F32) * 0.7)  # ochre stones
    shade = 0.85 + 0.15 * smoothstep(0, 4, height)
    col = grey * shade[..., None] * (1 + 0.06 * f.spectral(0.5, 120, 500))[..., None]
    tar = rgb(0.10, 0.10, 0.10)
    col = mix(tar, col, stone)
    moss = blotches(f, 0.15, 0.15, 1, 20)
    col = mix(col, rgb(0.32, 0.34, 0.22), 0.5 * moss * (1 - stone * 0.6))
    dirt = blotches(f, 0.35, 0.25, 1, 14)
    col = multiply(col, rgb(0.72, 0.68, 0.60), 0.5 * dirt)
    puddle = blotches(f, 0.12, 0.1, 1, 16)
    col = multiply(col, rgb(0.55, 0.55, 0.55), 0.6 * puddle)
    rough = lerp(np.full((n, n), 0.9, F32), 0.62, 1 - stone)
    rough = lerp(rough, 0.35, puddle * 0.8)
    return Surface(np.clip(col, 0, 1), height, 0.35, np.clip(rough, 0, 1), reference=ref)


# -- Overlays (alpha decals) ------------------------------------------------------------------------------------


def _vertical_profile(f: Field, top: float, wobble: float) -> np.ndarray:
    """0 above a wavy line at `top` (fraction of height from the top), 1 below; wraps along x only."""
    n = f.n
    line = f.spectral(2.8, 1, 16)[0:1, :] + 0.08 * f.spectral(2.0, 10, 60)[0:1, :]
    line = top * n + wobble * n * line  # one row of periodic noise: periodic in x
    return smoothstep(-3, 3, f.y - line)


def wall_grime(f: Field) -> Surface:
    """Rising damp and mop splash along the base of a wall: one strip, tiling along x only."""
    n = f.n
    body = _vertical_profile(f, 0.58, 0.06)
    depth = np.clip((f.y / n - 0.58) / 0.42, 0, 1)
    rim = np.clip(f.blur(body, 2.0) - f.blur(body, 7.0), 0, 1) * 4  # tide line at the top of the damp
    mottling = f.fbm01(1.8, 3, 200)
    alpha = body * (0.35 + 0.45 * depth ** 1.4 + 0.2 * mottling) + 0.5 * np.clip(rim, 0, 1)
    k = 1400
    sy = n - np.abs(f.rng.normal(0, 0.18 * n, k))  # mop splash: thick near the floor, thinning upward
    splash = np.clip(f.splat(f.rng.uniform(0, n, k), sy, f.rng.uniform(0.2, 0.8, k), 2.0, 0.8), 0, 1)
    alpha = np.clip(alpha + 0.45 * splash, 0, 0.95)
    alpha *= smoothstep(0.02 * n, 0.12 * n, f.y)  # nothing in the top rows: the strip never shows a seam
    col = lerp(rgb(0.30, 0.25, 0.18), rgb(0.12, 0.10, 0.07), depth[..., None])
    col = multiply(col, rgb(0.7, 0.6, 0.5), np.clip(rim, 0, 1))
    col = mix(col, rgb(0.20, 0.22, 0.15), 0.3 * blotches(f, 0.2, 0.2, 2, 20))  # a little green mould
    return Surface(np.clip(col, 0, 1), np.zeros((n, n), F32), 0.0, alpha=alpha.astype(F32), reference=rgb(1, 1, 1))


def floor_dirt(f: Field) -> Surface:
    """Tracked-in dirt, dust and grit; tiles both ways."""
    n = f.n
    patches = blotches(f, 0.45, 0.3, 1, 16)
    fine = f.fbm01(1.0, 30, 400)
    smudge = np.clip(f.strokes(60, (40, 160), (6, 14), wobble=0.03, intensity=(0.2, 0.6)), 0, 1)
    grit = np.clip(f.splat(f.rng.uniform(0, n, 4000), f.rng.uniform(0, n, 4000), f.rng.uniform(0.3, 1, 4000), 1.8, 0.8), 0, 1)
    alpha = np.clip(patches * (0.25 + 0.45 * fine) + 0.35 * smudge * patches + 0.6 * grit, 0, 0.85)
    col = lerp(rgb(0.34, 0.29, 0.22), rgb(0.18, 0.15, 0.11), fine[..., None])
    return Surface(np.clip(col, 0, 1), np.zeros((n, n), F32), 0.0, alpha=alpha.astype(F32), reference=rgb(1, 1, 1))


def rust_streaks(f: Field) -> Surface:
    """Rust bleeding down from a pipe, bracket or grille line along the top: one strip, tiling along x."""
    n = f.n
    k = 60
    sx = f.rng.uniform(0, n, k)
    sy = f.rng.uniform(0.08 * n, 0.2 * n, k)
    runs = np.clip(f.drips(0, (120, 760), (2, 5), wobble=0.04, head=2.0, sources=(sx, sy)), 0, 1)
    runs = np.clip(runs * 0.8 + f.directional_blur(runs, 6, 1) * 1.6, 0, 1)
    band = smoothstep(0.06 * n, 0.12 * n, f.y) * smoothstep(0.30 * n, 0.14 * n, f.y)
    source = band * blotches(f, 0.6, 0.25, 1, 20)
    alpha = np.clip(runs * 0.75 + source * 0.55, 0, 0.85)
    alpha *= smoothstep(0.02 * n, 0.08 * n, f.y) * smoothstep(n * 0.99, n * 0.85, f.y)
    tone = f.fbm01(1.4, 4, 200)
    col = lerp(rgb(0.30, 0.17, 0.09), rgb(0.50, 0.30, 0.15), tone[..., None])
    return Surface(np.clip(col, 0, 1), np.zeros((n, n), F32), 0.0, alpha=alpha.astype(F32), reference=rgb(1, 1, 1))


def crack_overlay(f: Field) -> Surface:
    """A few jagged cracks with a faint dirty halo; tiles both ways."""
    n = f.n
    main = f.strokes(4, (300, 800), (1.4, 2.4), wobble=0.09, intensity=(0.9, 1.0))
    branch = f.strokes(22, (30, 180), (0.9, 1.6), wobble=0.14, intensity=(0.6, 1.0))
    line = np.clip(main * 1.5 + branch * 1.2, 0, 1)
    halo = np.clip(f.blur(line, 4.0) * 2.5, 0, 1)
    alpha = np.clip(line * 0.95 + halo * 0.3, 0, 0.95)
    col = lerp(rgb(0.30, 0.27, 0.23), rgb(0.06, 0.05, 0.05), line[..., None])
    return Surface(np.clip(col, 0, 1), np.zeros((n, n), F32), 0.0, alpha=alpha.astype(F32), reference=rgb(1, 1, 1))


RECIPES = {
    "PaintedPlaster": painted_plaster,
    "CheckerTile": checker_tile,
    "StainedConcrete": stained_concrete,
    "CeilingTile": ceiling_tile,
    "RustedMetal": rusted_metal,
    "GalvanizedMetal": galvanized_metal,
    "WornWood": worn_wood,
    "PoolMosaic": pool_mosaic,
    "StainedBrick": stained_brick,
    "VinylTile": vinyl_tile,
    "LabWorktop": lab_worktop,
    "RubberMat": rubber_mat,
    "RoofGravel": roof_gravel,
    "WallGrime": wall_grime,
    "FloorDirt": floor_dirt,
    "RustStreaks": rust_streaks,
    "Cracks": crack_overlay,
}

__all__ = ["RECIPES", "Surface", "norm01"]
