"""Seamless texture toolkit for the Rovloc material generator.

Every field lives on an N x N torus: noise is synthesised in the frequency domain with integer frequencies only,
cellular noise measures toroidal distances, splats wrap their indices, and derivatives use wrapped neighbours. So
every map tiles with no seam, in both directions, by construction.

Conventions: arrays are float32 indexed [row, col]; row grows downward in the image. Height fields are in pixels
(a slope of 1 is 45 degrees). Normal maps are tangent space, OpenGL / Roblox convention: +X right (red), +Y up the
image (green), +Z out of the surface (blue); a flat texel is (128, 128, 255).
"""

from __future__ import annotations

import numpy as np

F32 = np.float32


class Field:
    """Deterministic field synthesis on an n x n torus."""

    def __init__(self, seed: int, n: int = 1024):
        self.n = n
        self.rng = np.random.default_rng(seed)
        fy = np.fft.fftfreq(n) * n
        fx = np.fft.rfftfreq(n) * n
        self._fx = fx[None, :].astype(np.float64)
        self._fy = fy[:, None].astype(np.float64)
        rows, cols = np.mgrid[0:n, 0:n]
        self.y = rows.astype(F32) + F32(0.5)
        self.x = cols.astype(F32) + F32(0.5)

    # -- noise ------------------------------------------------------------------------------------------------

    def spectral(
        self,
        beta: float = 2.0,
        fmin: float = 1.0,
        fmax: float | None = None,
        stretch: tuple[float, float] = (1.0, 1.0),
        angle: float = 0.0,
    ) -> np.ndarray:
        """Power-law noise (amplitude ~ f^-beta/2) between fmin and fmax cycles per tile, zero mean, unit std.

        `stretch` = (sx, sy) squeezes the spectrum: sy > 1 makes features long vertically (streaks), sx > 1 long
        horizontally. `angle` (radians) rotates the anisotropy. Integer frequencies keep it perfectly periodic.
        """
        n = self.n
        white = self.rng.standard_normal((n, n))
        spectrum = np.fft.rfft2(white)
        fx, fy = self._fx, self._fy
        if angle:
            c, s = np.cos(angle), np.sin(angle)
            fx, fy = fx * c - fy * s, fx * s + fy * c
        fr = np.sqrt((fx * stretch[0]) ** 2 + (fy * stretch[1]) ** 2)
        fr[0, 0] = 1.0
        amp = fr ** (-beta / 2.0)
        amp[fr < fmin] = 0.0
        if fmax is not None:
            amp *= np.exp(-((fr / fmax) ** 2))
        amp[0, 0] = 0.0
        out = np.fft.irfft2(spectrum * amp, s=(n, n))
        out -= out.mean()
        std = out.std()
        return (out / (std if std > 0 else 1.0)).astype(F32)

    def fbm01(self, beta: float = 2.0, fmin: float = 1.0, fmax: float | None = None, **kw) -> np.ndarray:
        """Spectral noise remapped to 0..1 by its own 0.5 / 99.5 percentiles."""
        return norm01(self.spectral(beta, fmin, fmax, **kw))

    def blur(self, img: np.ndarray, sigma: float) -> np.ndarray:
        """Periodic Gaussian blur (sigma in pixels)."""
        if sigma <= 0:
            return img
        n = self.n
        g = np.exp(-2.0 * (np.pi**2) * (sigma**2) * ((self._fx / n) ** 2 + (self._fy / n) ** 2))
        return np.fft.irfft2(np.fft.rfft2(img) * g, s=(n, n)).astype(F32)

    def directional_blur(self, img: np.ndarray, sigma_x: float, sigma_y: float) -> np.ndarray:
        """Periodic anisotropic Gaussian blur."""
        n = self.n
        g = np.exp(-2.0 * (np.pi**2) * ((sigma_x * self._fx / n) ** 2 + (sigma_y * self._fy / n) ** 2))
        return np.fft.irfft2(np.fft.rfft2(img) * g, s=(n, n)).astype(F32)

    def worley(self, cells: int, jitter: float = 0.9, aspect: float = 1.0):
        """Toroidal cellular noise with one feature point per cell of a cells x (cells*aspect) lattice.

        Returns (f1, f2, cell_value): distances in pixels to the nearest and second nearest points, and a random
        0..1 value per nearest cell (stable per cell)."""
        n = self.n
        cx, cy = cells, max(1, int(round(cells * aspect)))
        sx, sy = n / cx, n / cy
        jx = self.rng.random((cy, cx)).astype(F32) * jitter + (1 - jitter) / 2
        jy = self.rng.random((cy, cx)).astype(F32) * jitter + (1 - jitter) / 2
        val = self.rng.random((cy, cx)).astype(F32)
        ix = np.floor(self.x / sx).astype(np.int32)
        iy = np.floor(self.y / sy).astype(np.int32)
        f1 = np.full((n, n), np.inf, F32)
        f2 = np.full((n, n), np.inf, F32)
        v1 = np.zeros((n, n), F32)
        for oy in (-1, 0, 1):
            for ox in (-1, 0, 1):
                gx = ix + ox
                gy = iy + oy
                wx = gx % cx
                wy = gy % cy
                px = (gx + jx[wy, wx]) * sx
                py = (gy + jy[wy, wx]) * sy
                dx = px - self.x
                dy = py - self.y
                dx -= n * np.round(dx / n)
                dy -= n * np.round(dy / n)
                d = np.sqrt(dx * dx + dy * dy)
                closer = d < f1
                f2 = np.where(closer, f1, np.minimum(f2, d))
                v1 = np.where(closer, val[wy, wx], v1)
                f1 = np.where(closer, d, f1)
        return f1, f2, v1

    def warp(self, img: np.ndarray, dx: np.ndarray, dy: np.ndarray) -> np.ndarray:
        """Samples img at (x + dx, y + dy) with periodic bilinear interpolation."""
        return sample(img, self.x - 0.5 + dx, self.y - 0.5 + dy)

    # -- splats -----------------------------------------------------------------------------------------------

    def splat(self, xs, ys, weights, radius: float, sigma: float | None = None) -> np.ndarray:
        """Sums a Gaussian dab of `sigma` (default radius/2) per point, wrapped. xs/ys/weights are 1-D arrays."""
        n = self.n
        sigma = sigma if sigma is not None else max(radius / 2.0, 0.5)
        r = int(np.ceil(radius))
        out = np.zeros(n * n, np.float64)
        xs = np.asarray(xs, np.float64)
        ys = np.asarray(ys, np.float64)
        weights = np.asarray(weights, np.float64)
        bx = np.floor(xs).astype(np.int64)
        by = np.floor(ys).astype(np.int64)
        fx = xs - bx
        fy = ys - by
        for oy in range(-r, r + 1):
            for ox in range(-r, r + 1):
                ddx = ox - fx + 0.5
                ddy = oy - fy + 0.5
                w = weights * np.exp(-(ddx * ddx + ddy * ddy) / (2 * sigma * sigma))
                idx = ((by + oy) % n) * n + ((bx + ox) % n)
                out += np.bincount(idx, weights=w, minlength=n * n)
        return out.reshape(n, n).astype(F32)

    def strokes(
        self,
        count: int,
        length: tuple[float, float],
        width: tuple[float, float],
        angle: tuple[float, float] = (0.0, np.pi),
        wobble: float = 0.0,
        taper: bool = True,
        intensity: tuple[float, float] = (0.5, 1.0),
        step: float = 0.7,
    ) -> np.ndarray:
        """Thin wandering lines (scratches, cracks, fibres). Lengths and widths in pixels."""
        xs, ys, ws = [], [], []
        rng = self.rng
        max_w = width[1]
        for _ in range(count):
            ln = rng.uniform(*length)
            steps = max(2, int(ln / step))
            a0 = rng.uniform(*angle)
            turn = np.cumsum(rng.normal(0, wobble, steps)) if wobble > 0 else np.zeros(steps)
            a = a0 + turn
            px = rng.uniform(0, self.n) + np.cumsum(np.cos(a) * step)
            py = rng.uniform(0, self.n) + np.cumsum(np.sin(a) * step)
            t = np.linspace(0, 1, steps)
            prof = np.sin(np.pi * t) ** 0.6 if taper else np.ones(steps)
            xs.append(px)
            ys.append(py)
            ws.append(prof * rng.uniform(*intensity))
        w = rng.uniform(*width)
        return self.splat(np.concatenate(xs), np.concatenate(ys), np.concatenate(ws) * step, max_w * 1.5, w * 0.5)

    def drips(
        self,
        count: int,
        length: tuple[float, float],
        width: tuple[float, float],
        wobble: float = 0.15,
        head: float = 1.0,
        sources: tuple[np.ndarray, np.ndarray] | None = None,
    ) -> np.ndarray:
        """Water / rust runs: lines that start at a point and run down the image, fading and thinning.

        `sources` optionally fixes the start points (xs, ys). Returns intensity ~0..1 (overlaps add)."""
        rng = self.rng
        xs, ys, ws = [], [], []
        if sources is not None:
            sx, sy = sources
            count = len(sx)
        for i in range(count):
            ln = rng.uniform(*length)
            steps = max(4, int(ln))
            x0 = sx[i] if sources is not None else rng.uniform(0, self.n)
            y0 = sy[i] if sources is not None else rng.uniform(0, self.n)
            drift = np.cumsum(rng.normal(0, wobble, steps))
            drift = np.convolve(drift, np.ones(9) / 9, mode="same")
            px = x0 + drift
            py = y0 + np.arange(steps, dtype=np.float64)
            t = np.linspace(0, 1, steps)
            fade = (1 - t) ** 1.3 * (0.6 + 0.4 * head * np.exp(-t * 12))
            pulse = np.convolve(rng.random(steps + 40), np.ones(41) / 41, mode="valid")[:steps]
            pulse = np.clip((pulse - 0.5) * 6 + 0.75, 0.15, 1.0)  # runs thicken, thin and break along their way
            xs.append(px)
            ys.append(py)
            ws.append(fade * pulse * rng.uniform(0.5, 1.0))
        w = rng.uniform(*width)
        return self.splat(np.concatenate(xs), np.concatenate(ys), np.concatenate(ws), w * 1.6, w * 0.55)


# -- pure helpers -----------------------------------------------------------------------------------------------


def sample(img: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Periodic bilinear sample of img at float pixel coordinates (x right, y down)."""
    n_rows, n_cols = img.shape
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = (x - x0).astype(F32)
    fy = (y - y0).astype(F32)
    x0 %= n_cols
    y0 %= n_rows
    x1 = (x0 + 1) % n_cols
    y1 = (y0 + 1) % n_rows
    a = img[y0, x0] * (1 - fx) + img[y0, x1] * fx
    b = img[y1, x0] * (1 - fx) + img[y1, x1] * fx
    return (a * (1 - fy) + b * fy).astype(F32)


def norm01(a: np.ndarray, lo: float = 0.5, hi: float = 99.5) -> np.ndarray:
    p0, p1 = np.percentile(a, [lo, hi])
    return np.clip((a - p0) / max(p1 - p0, 1e-6), 0, 1).astype(F32)


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return (t * t * (3 - 2 * t)).astype(F32)


def lerp(a, b, t):
    return a + (b - a) * t


def rgb(r: float, g: float, b: float) -> np.ndarray:
    return np.array([r, g, b], F32)


def mix(base: np.ndarray, color, t: np.ndarray) -> np.ndarray:
    """Blends an (n, n, 3) image toward `color` (rgb triple or (n, n, 3) image) by t (n, n)."""
    t3 = t[..., None]
    return base * (1 - t3) + np.asarray(color, F32) * t3


def multiply(base: np.ndarray, color, t: np.ndarray) -> np.ndarray:
    """Multiplies an (n, n, 3) image by `color`, weighted by t (stains darken and tint what is under them)."""
    t3 = t[..., None]
    return base * (1 - t3 + np.asarray(color, F32) * t3)


def solid(n: int, color) -> np.ndarray:
    return np.broadcast_to(np.asarray(color, F32), (n, n, 3)).copy()


def normal_map(height: np.ndarray, strength: float = 1.0) -> np.ndarray:
    """Tangent-space OpenGL normal map (uint8 RGB) from a periodic height field in pixels."""
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    nx = -dx * strength
    ny = dy * strength  # +Y points up the image: rising toward the bottom of the image faces up
    nz = np.ones_like(nx)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx * inv, ny * inv, nz * inv], axis=-1)
    return np.clip(np.round((n * 0.5 + 0.5) * 255), 0, 255).astype(np.uint8)


def to_u8(img: np.ndarray) -> np.ndarray:
    return np.clip(np.round(img * 255), 0, 255).astype(np.uint8)


class Grid:
    """A periodic tile / brick / plank layout: per-pixel tile id, distance to the nearest joint, tile-local coords."""

    def __init__(self, tile_id: np.ndarray, edge: np.ndarray, u: np.ndarray, v: np.ndarray, count: int):
        self.id = tile_id
        self.edge = edge  # pixels from the nearest joint centre line (0 on the joint)
        self.u = u
        self.v = v
        self.count = count

    def per_tile(self, values: np.ndarray) -> np.ndarray:
        return values[self.id]


def tile_grid(n: int, cols: int, rows: int, row_shift: float = 0.0) -> Grid:
    """cols x rows rectangular tiles; each row shifted by row_shift * tile width (0.5 = running bond)."""
    y = np.arange(n, dtype=F32)[:, None] + 0.5
    x = np.arange(n, dtype=F32)[None, :] + 0.5
    th = n / rows
    tw = n / cols
    r = np.floor(y / th).astype(np.int64)
    xs = (x - (r % 2) * row_shift * tw) % n if row_shift else np.broadcast_to(x, (n, n))
    c = np.floor(xs / tw).astype(np.int64) % cols
    u = xs - c * tw
    v = np.broadcast_to(y - r * th, (n, n))
    edge = np.minimum(np.minimum(u, tw - u), np.minimum(v, th - v))
    tile_id = (np.broadcast_to(r, (n, n)) * cols + c).astype(np.int64)
    return Grid(tile_id, edge.astype(F32), (u / tw).astype(F32), (v / th).astype(F32), rows * cols)


def plank_grid(n: int, rows: int, rng: np.random.Generator, length: tuple[float, float]) -> Grid:
    """Rows of planks running along x with random lengths and staggered joints (all wrap-safe)."""
    th = n / rows
    y = np.arange(n, dtype=F32) + 0.5
    r = np.floor(y / th).astype(np.int64)
    v_row = y - r * th
    tile_id = np.zeros((n, n), np.int64)
    edge = np.zeros((n, n), F32)
    u = np.zeros((n, n), F32)
    x = np.arange(n, dtype=F32) + 0.5
    count = 0
    for row in range(rows):
        cuts = [rng.uniform(0, n)]
        while True:
            nxt = cuts[-1] + rng.uniform(*length)
            if nxt - cuts[0] > n - length[0] * 0.6:
                break
            cuts.append(nxt)
        cuts = np.array(cuts) % n
        cuts.sort()
        rel = (x[None, :] - cuts[:, None]) % n  # distance past each cut
        seg = np.argmin(np.where(rel >= 0, rel, np.inf), axis=0)
        past = rel[seg, np.arange(n)]
        seg_len = np.diff(np.concatenate([cuts, cuts[:1] + n]))
        lengths = seg_len[seg]
        sel = r == row
        tile_id[sel, :] = count + seg[None, :]
        ue = np.minimum(past, lengths - past)
        ve = np.minimum(v_row[sel], th - v_row[sel])
        edge[sel, :] = np.minimum(ue[None, :], ve[:, None])
        u[sel, :] = (past / lengths)[None, :]
        count += len(cuts)
    v = np.broadcast_to((v_row / th)[:, None], (n, n)).astype(F32)
    return Grid(tile_id, edge, u, v, count)
