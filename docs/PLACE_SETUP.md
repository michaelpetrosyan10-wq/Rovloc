# Place setup

Some settings can't come from `default.project.json`. Either they're universe settings stored on Roblox's
servers, or they're read-only to the project file. Do these once per experience. `ServerMain` checks the critical
ones at boot. If any is wrong, it sets `ReplicatedStorage.BootError`, and the loading curtain shows it instead of
staying black.

## 1. Bootstrap the place file (Rojo users)

`rojo serve` can't write NotScriptable properties (most Workspace and StarterPlayer pins, and `Lighting.Technology`).
Always start from a built place:

```sh
rokit install
rojo build -o Rovloc.rbxl
```

Open `Rovloc.rbxl` in Studio, publish it (File → Publish to Roblox), then run `rojo serve` and connect the
Rojo plugin into that same place. Never live-sync into a fresh Studio template.

**Studio-only users.** Open the `Rovloc.rbxl` artifact attached to the latest CI run (or build it once with the
command above). Every script, folder and engine pin is already in place.

## 2. Settings Rojo can't set

| Setting | Where | Value | Why |
| --- | --- | --- | --- |
| Server size | Creator Dashboard → Places → Server Size | **4** | `Players.MaxPlayers` is read-only. Four parachute packs, airlock waits and perk balance assume a 1–4 squad. `LobbyService` also turns any extra player into a spectator. |
| Studio API access | Game Settings → Security → Enable Studio Access to API Services | On (for DataStore testing) | Without it, `StoreBackend` falls back to the in-memory Ephemeral store and shows a "progress not saved" banner. |
| Avatar type | Game Settings → Avatar | R15 | Belt and braces: `CharacterService` already builds R15 rigs explicitly. |
| Character controller | Avatar Settings → Character Controller | Legacy Humanoid | Matches `StarterPlayer.LuaCharacterController = Legacy`. Bear-trap locks, kinematic states and crouch heights assume Humanoid physics. |
| Avatar scaling / bundles | Avatar Settings | Standard scale, no body bundles | `CharacterService` also normalizes every HumanoidDescription (scales 1, body type 0, no layered clothing or head accessories) so eye heights and the 3.5×3.5 vents stay correct. |

## 3. Syncing Studio edits back

```sh
rojo syncback syncback.project.json --input Rovloc.rbxl
git checkout -- syncback.project.json
```

`syncback.project.json` maps only the script trees. That keeps syncback from rewriting the engine pins in
`default.project.json`. Sync Studio-side edits back before anyone next runs `rojo serve`, because serve
deletes instances under `$path` nodes that don't exist on disk.
