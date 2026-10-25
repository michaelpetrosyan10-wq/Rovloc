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

## 3. Publishing without Studio (phone-friendly)

`.github/workflows/publish.yml` builds the place with Rojo and uploads it through Roblox's Open Cloud
[place publishing API](https://create.roblox.com/docs/cloud/guides/usage-place-publishing). Everything below works
in a phone browser.

1. **An experience to publish into.** The API updates an existing place; it cannot create a new experience. Create
   one from the [Creator Dashboard](https://create.roblox.com/dashboard/creations) if your browser offers it;
   otherwise one short Studio session on any computer (publish an empty Baseplate) is enough, once.
2. **Ids.** On the Creator Dashboard, open the experience: the universe id is in the experience's URL / "Copy
   Universe ID" menu item; the start place id is in the place's Configure URL.
3. **API key.** Creator Dashboard → Credentials → API Keys → Create API Key. Add the `universe-places` API system,
   select the experience, and grant **Write**. Copy the key once.
4. **GitHub secrets.** In the repository: Settings → Secrets and variables → Actions → New repository secret:
   `ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID`, `ROBLOX_PLACE_ID`.
5. **Publish.** Actions → *Publish to Roblox* → Run workflow (choose `Saved` for a private draft or `Published` for
   live). Pushes to `main` publish automatically.
6. **Play.** Open the experience in the Roblox app on your phone. Keep the experience private while testing.

Dev tools: add your Roblox UserId to `GameConfig.DevAllowlistUserIds` to get the on-screen dev panel (start a run,
skip levels, show noise rings) in live servers. In Studio it is always available.

## 4. Syncing Studio edits back

```sh
rojo syncback syncback.project.json --input Rovloc.rbxl
git checkout -- syncback.project.json
```

`syncback.project.json` maps only the script trees. That keeps syncback from rewriting the engine pins in
`default.project.json`. Sync Studio-side edits back before anyone next runs `rojo serve`, because serve
deletes instances under `$path` nodes that don't exist on disk.
