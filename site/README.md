# Rovloc (web)

What Vercel serves at rovloc.vercel.app: the published game at the root and the work in progress under `/beta/`.

- `index.html`: the stable game, one self-contained file. No build writes it; it changes only when a beta is promoted.
- `beta/`: the build players test at rovloc.vercel.app/beta/, written by `cd web && npm run build`:
  - `beta/index.html`: the page, with the asset manifest inline;
  - `beta/assets/`: content-hashed files: the bundle, the world data (`world.*.json.gz`, `world.*.bin.gz`), the decal
    and wear atlases, and every texture map at every graphics tier's size (2048 Max, 1024 High / Medium, 512 Low,
    256 Potato).

  The page boots on the 256 px set (the Potato colour maps) and streams the chosen tier's set in the background, so a
  Chromebook on Potato downloads only light assets. Every reference is relative to the page, so the build works from
  the path its directory is served at.
- `vercel.json`: the stable page keeps its hour of cache; `beta/assets/` is cached forever (the names change with the
  bytes) and `beta/index.html` is revalidated on every visit; `/beta` redirects to `/beta/` (`trailingSlash`), which
  the page's relative assets need.

Both pages are one origin, so they share the saved game (`localStorage`).

## Publishing a beta

```sh
cd web
node tools/build.mjs --stamp "BETA 10 NOV"   # site/beta/ and dist/Rovloc-lite.html; the title screen shows the stamp
node tools/check.mjs                          # serves site/ as Vercel does and plays the beta at /beta/
```

Commit `site/beta/` and push. `npm run check` builds first, without a stamp: build with `--stamp` again before
committing a beta. Promoting a beta to the root is `node tools/build.mjs --site ../site`, with `vercel.json`'s rules
and `SITE_PATH` in `web/tools/check.mjs` moved to the root with it.

The same build writes `web/dist/Rovloc-lite.html`, a single file with the Low and Potato sets inline, for offline
Chromebook use (it opens from `file://`).
