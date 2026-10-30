# Lighting parity: Roblox and the browser build

Players said the Roblox build is "very dark compared to the website". The browser build (`web/`, rovloc.vercel.app) is
the look we are matching. This page compares the two pipelines, explains why Roblox reads darker, and lists the
Roblox values that reproduce the web's frame. Each level's numbers are given before and after the change.

- **The values** are data: `LightingMood.render(layoutId)` (`RENDER_PATCHES` over `BASE_RENDER`) in
  `src/ReplicatedStorage/Shared/World/ProceduralWorldBuilder/LightingMood.luau`.
- **The writers** are on the client:
  - `LightingController/Film` writes the exposure, grade, fills and haze;
  - `LightingController` writes the fixture gain and range;
  - `Volumetrics` writes the moonlight spills;
  - `Flashlight` and `RemoteFlashlightRenderer` write the torch.
- **The shared data stays as it is.** The web export reads it: the layouts, `LightingMood.resolve`, the moods and films,
  the moonlight and `LightingRig.Baseline`. Changing any of it would move the reference.

Roblox can't be rendered in the sandbox, so the numbers come from a model of both pipelines run on the same points:

- every room's floor, sampled on a 2-stud grid;
- the burning lights of that room, so walls stop light;
- grey albedo 0.3;
- display luminance from 0 to 255.

The model's web side was checked against the real web bake (`web/build/world.bin`, the floor vertices of each level,
weighted by area, through the web's post). It agrees within about 22/255 (closer on most levels). The model ignores
shadows, and it does so the same way for both sides.

## 1. The two pipelines

| Stage | Web (the reference) | Roblox before |
| --- | --- | --- |
| Light falloff | `(1-(d/R)²)² / (1 + 0.004 d²)` (`materials.js`, `bake/light.mjs`) | Future: the same window over `1 / (1 + 0.012 d²)`, the body the bake documents as Roblox-like before it was softened to 0.004 |
| Burning set | Every burning fixture, baked | The same set, but only the nearest 16 / 30 / 48 (Low / Medium / High) are enabled |
| Indoor fill | 4.5 × rig `Ambient` (linear), times baked AO (strength 0.85) | rig `Ambient` (24, 27, 35) as is, no AO |
| Outdoor fill | 2.2 × rig `OutdoorAmbient` times sky openness, plus the indoor fill | rig `OutdoorAmbient` (44, 49, 62) |
| Exposure | `2^(0.3 + film.exposure + 0.25)`, +0.8 EV more in the lobby (`ExposureTrim`); the torch is not trimmed | `0.3 + film.exposure` |
| Tone curve | ACES (Narkowicz), what the bake was tuned with at Roblox's exposure | Future / Realistic filmic curve (taken as the same) |
| Grade | lift, then contrast as an S-curve through **0.16** with slope 1 + contrast, saturation, × area tint | `ColorCorrection`: contrast about **0.5**, + Brightness, saturation, × base tint (232, 240, 255) × area tint |
| Fog | exp², coefficient `density × 0.02` per stud, grey-blue haze colour, no haze layer | `Atmosphere` Density plus Haze 1.4–2.6, lit by a night sky |
| Torch | inner 38° / 60 studs / 9, outer 80° / 48 studs / 2.2 | the same cones |

## 2. Why Roblox read darker

The causes are listed largest first.

1. **The contrast pivot.** `ColorCorrection.Contrast` 0.2 about mid-grey, with the 0.015 lift, maps every display value
   under about 0.07 (18/255; 0.05 in the lobby) to pure black. The night frame lives down there: the web's 10th percentile is 27/255 on every school floor.
   So the gaps between pools, and on most floors even the median, were 0 on Roblox. The web's renderer comment warns
   about exactly this: "pivoting at mid-grey would crush this night-time frame". This is the biggest single cause.
2. **The fill.** Roblox's ambient was 4.5 times weaker (in linear light) than the web's fill between the pools. Its
   outdoor fill was 3.6 times weaker.
3. **Exposure.** Roblox ran 0.25 EV under the web, and 1.05 EV under it in the lobby.
4. **Falloff.** On a 22.5-stud tube, Roblox's pool is 0.71 of the web's at 8 studs, 0.58 at 12 and 0.50 at 16. The torch
   throws 0.45 of the web's light at 20 studs and 0.38 at 40.
5. **An extra cold tint.** The base grade's (232, 240, 255) sat on top of the area grade, costing 6% of the luminance.
   The web grades with the area tint alone.
6. **Haze.** Roblox's Haze layer, which the web doesn't have, reads as near-black murk at night.

Two suspects turned out not to be causes:

- **Broken fixtures.** Both builds burn the same set, because the web bakes the built place. The burning share is
  36/66 on L0, 76/184 on L1, 104/188 on L2, 57/110 on L3, 47/88 on L4, 8/10 on the roof and 13/13 in the lobby.
- **The active-set budget.** The nearest 16 burning fixtures reach a median 49–108 studs from any floor point. A pool
  reaches about 25 studs, so only distant pools down long corridors drop out, and only on Low.

## 3. The mapping (`LightingMood.render`)

| Field | How it is set |
| --- | --- |
| `exposure` | The web's exposure: 0.3 + the film's exposure + 0.25, plus 0.8 in the lobby. |
| `contrast`, `brightness` | A least-squares fit of Roblox's linear contrast (about 0.5) plus its additive Brightness to the web's lift and S-curve, over display values 0.005–0.5. The worst error is 1.4–2.4/255. The fit's line crosses identity near black (about 0.02), so black stays black, and its slope is about 1.15 above that, which is the S-curve's average slope over the night range. |
| `tint` | White. The area grade (`LightingMood.grade`) carries the level's colour, as on the web. |
| `ambient` | (24, 27, 35) → **(51, 56, 70)**: the web's fill at its mean AO, 4.5 × 0.8 in linear light. Roblox has no AO, so the flat fill sits at the web's average. Corners keep their darkness from the pools, not from AO. |
| `outdoorAmbient` | (44, 49, 62) → **(85, 93, 115)**: the web's outdoor fill, plus its ambient on open ground (AO 0.85). |
| `haze` | 0.4 × the film's haze. Density stays the film's, because the web's fog is ported 1:1 from it. |
| `fixtureGain`, `fixtureRange` | A grid search per level that minimises the squared display error over every floor sample. Range stays capped at 60. |
| `torch` | A fit of both cones' Brightness to the web's beam from 4 to 40 studs. The outer cone's range goes from 48 to **60** on every level (`LightingMood.TorchOuterRange`). The lobby's gain is lower because the web leaves its torch untrimmed while the lobby gets +0.8 EV. |

Each level's values, before → after:

| Level | ExposureCompensation | Contrast | Brightness | Haze | Fixture gain | Range × | Torch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Lobby | 0.40 → 1.45 | 0.14 → 0.100 | 0.015 → 0.053 | 1.4 → 0.56 | 1 → 1.30 | 1 → 1.10 | 1 → 1.05 |
| L0 Basement | 0.35 → 0.60 | 0.20 → 0.145 | 0.015 → 0.069 | 2.4 → 0.96 | 1 → 1.25 | 1 → 1.10 | 1 → 1.70 |
| L1 Hallways | 0.38 → 0.63 | 0.20 → 0.145 | 0.015 → 0.069 | 1.9 → 0.76 | 1 → 1.65 | 1 → 1.05 | 1 → 1.70 |
| L2 Science | 0.40 → 0.65 | 0.20 → 0.145 | 0.015 → 0.069 | 1.7 → 0.68 | 1 → 1.65 | 1 → 1.05 | 1 → 1.70 |
| L3 Gym | 0.38 → 0.63 | 0.20 → 0.145 | 0.015 → 0.069 | 2.1 → 0.84 | 1 → 1.50 | 1 → 1.10 | 1 → 1.70 |
| L4 Pool | 0.42 → 0.67 | 0.22 → 0.155 | 0.015 → 0.074 | 2.6 → 1.04 | 1 → 1.65 | 1 → 1.05 | 1 → 1.70 |
| L5 Roof / outdoors | 0.50 → 0.75 | 0.16 → 0.115 | 0.015 → 0.058 | 2.2 → 0.88 | 1 → 1.75 | 1 → 1.00 | 1 → 1.70 |
| Any other layout (base) | 0.38 → 0.63 | 0.20 → 0.145 | 0.015 → 0.069 | 1.9 → 0.76 | 1 → 1.60 | 1 → 1.05 | 1 → 1.70 |

The gains differ by level because of geometry:

- the basement's low bulbs light the floor from close, where the two falloffs agree;
- the gym's high ceiling needs more reach;
- the roof's few lamps carry little next to the outdoor fill.

## 4. Per level: web, Roblox before and Roblox after

These are the floor display luminances (0–255): mean / 10th percentile / median / 90th percentile.

| Level | Web | Roblox before | Roblox after | Real web bake (floor mean) |
| --- | --- | --- | --- | --- |
| Lobby | 73.8 / 48.4 / 65.7 / 113.9 | 5.9 / 0 / 0 / 20.2 | 74.0 / 49.3 / 66.4 / 111.7 | 92.1 |
| L0 Basement | 32.7 / 27.0 / 27.0 / 42.5 | 1.9 / 0 / 0 / 0 | 32.4 / 26.2 / 26.2 / 44.3 | 31.9 |
| L1 Hallways | 76.2 / 27.6 / 65.4 / 141.6 | 20.7 / 0 / 3.3 / 56.7 | 75.8 / 26.8 / 64.3 / 141.3 | 64.1 |
| L2 Science | 87.4 / 28.0 / 90.3 / 155.0 | 26.0 / 0 / 18.4 / 68.3 | 87.2 / 27.2 / 88.3 / 156.0 | 73.1 |
| L3 Gym | 67.1 / 27.6 / 41.8 / 141.6 | 16.8 / 0 / 0 / 58.1 | 66.9 / 26.8 / 44.0 / 139.7 | 45.5 |
| L4 Pool | 48.9 / 28.3 / 28.3 / 106.6 | 7.3 / 0 / 0 / 27.7 | 48.7 / 27.8 / 27.8 / 104.1 | 40.0 |
| L5 Roof | 72.5 / 72.4 / 72.4 / 72.4 | 3.4 / 2.8 / 2.8 / 2.8 | 72.1 / 72.0 / 72.0 / 72.0 | 77.9 |

The mood survives. The spread between the 10th and 90th percentiles, which is the pools against the gaps, is the web's
to within about 3/255 on every level. The gaps sit at about 27/255, dark grey-blue rather than void, and the pools'
90th percentile runs from 44 (the basement) to 156 (the science hall).

**Torch throw.** These figures are for a grimy wall (albedo 0.15), at 20 and 40 studs:

| | 20 studs | 40 studs |
| --- | --- | --- |
| Web | 230–234 | 102–108 |
| Roblox before | 175–181 | 23–31 |
| Roblox after | 241–249 | 92–103 |

Within 10 studs, both builds clip the hotspot at about 250–255.

**Fog.** The web's fog fraction at 50 / 100 / 150 studs is:

| Level | 50 studs | 100 studs | 150 studs |
| --- | --- | --- | --- |
| Lobby | 0.08 | 0.27 | 0.51 |
| L0 | 0.16 | 0.51 | 0.80 |
| L1 | 0.11 | 0.37 | 0.65 |
| L2 | 0.10 | 0.34 | 0.60 |
| L3 | 0.13 | 0.44 | 0.73 |
| L4 | 0.19 | 0.57 | 0.85 |
| Roof | 0.12 | 0.41 | 0.69 |

Roblox keeps the same Density. With 0.4 × the Haze, the far end of a corridor fades toward the level's haze colour
instead of toward black.

## 5. The Brightness setting

`SettingsSchema` has a new setting, `Brightness`: −2 to +2 in whole steps, default 0. The menu shows it as "−2 … 0 …
+2".

Each step moves `ExposureCompensation` by 0.2 EV and scales both fills by 15% in linear light (`LightingMood.
BrightnessStep`). `Film` applies it on top of the render: `SettingsController` calls `LightingController.SetBrightness`.

On L1 the steps give these floor values (mean / 10th percentile):

| Step | −2 | −1 | 0 | +1 | +2 |
| --- | --- | --- | --- | --- | --- |
| Mean / p10 | 56.6 / 12.7 | 65.8 / 19.3 | 75.8 / 26.8 | 86.6 / 35.3 | 98.2 / 45.1 |

## 6. What does not change

- **Budgets.** `RenderBudgetController`'s counts are unchanged: fixtures 16 / 30 / 48, shadows, spills, shafts, dust and
  teammate torches. A fixture's range grows by 10% at most and stays capped at 60.
- **Scripted beats.** The gain multiplies only the Brightness that is finally written, after flicker, the power factor,
  overrides and bursts. So all of these keep their ratios:
  - the L0 power-off at `PowerOffFactor` and the stuttering switch-on;
  - flicker groups and blackouts;
  - the L1 classroom glow's override and its burst;
  - the L4 floodlights.

  Glow surfaces read the brightness before the gain, so tubes look as they did.
- **Lightning.** A flash still owns `ExposureCompensation`, `Brightness` and `OutdoorAmbient` while it runs, adding to
  the new rest values. `Film` writes its exposure and outdoor fill again as soon as the flash ends.

## 7. Assumptions, and how to check in Studio

These assumptions all hold the same way on each side of the model:

- Roblox applies `ColorCorrection.Contrast` about 0.5, then adds Brightness. If Brightness is added before the contrast
  instead, the equivalent Brightness is about 0.06; the difference is under 3/255.
- Future's falloff body is about `1/(1 + 0.012 d²)` inside the same range window.
- The Realistic tone curve is close to ACES at the same exposure.
- Lighting.Ambient is applied flat, with no AO.

**To check in Studio,** do this for each level:

1. Stand where the web's dev screenshots were taken (each level's spawn).
2. Take a screenshot with the flashlight off and another with it on.
3. Compare the mean luminance of each with the web at the same spot.
4. If they differ, nudge that level's `RENDER_PATCHES` entry: `exposure` for the overall level, `fixtureGain` for the
   pools, `ambient` for the gaps.

Players on dark or bright screens can use the Brightness setting.
