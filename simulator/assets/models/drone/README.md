# Textured drone model

Visual-only quadcopter model used by the render layer
(`simulator/scenes/visuals/drone_visual_textured.tscn`). It plays no role in
the deterministic simulation: no collision, no physics, no observations.

## Provenance

| Field | Value |
|---|---|
| Asset name | Drone |
| Creator | NateGazzard |
| Source URL | https://poly.pizza/m/DNbUoMtG3H |
| Licence | Creative Commons Attribution 3.0 (CC-BY 3.0), https://creativecommons.org/licenses/by/3.0/ |
| Required attribution | "Drone" by NateGazzard [CC-BY 3.0] via Poly Pizza (see `THIRD_PARTY_ASSETS.md`) |
| Original filename | `4eb88feb-cb2d-46c3-980d-3e704868361c.glb` (poly.pizza static CDN name) |
| Download date | 2026-08-01 |
| Download interface | Direct public GLB link from the model page (`https://static.poly.pizza/4eb88feb-cb2d-46c3-980d-3e704868361c.glb`); no account required |
| Formats offered by source | glTF (GLB) and OBJ |
| Format imported here | glTF 2.0 binary (GLB), self-contained |

SHA-256 of the downloaded file:
`bc9f0d765e0fdb838a9baf26b472f955a11bb2509a3337e918054241b134638d`

## Why this asset (primary asset fallback)

The milestone's primary choice was "Low Poly Quadcopter Drone – Game Ready PBR
Asset" by SerhiiKo (https://sketchfab.com/mr-falk),
https://sketchfab.com/3d-models/low-poly-quadcopter-drone-game-ready-pbr-asset-65d0bfcf9c5a479ebb19215a261b8497,
listed under Creative Commons Attribution with a full PBR map set (Base Color,
Normal, Roughness, Metallic, Height). On 2026-08-01 its official download
routes were checked without credentials:

- `https://api.sketchfab.com/v3/models/65d0bfcf9c5a479ebb19215a261b8497/download`
  returned **HTTP 401** (a Sketchfab account / API token is required).
- The model-page download endpoint requires the same authenticated session.

Per the milestone rules ("do not scrape around authentication … if the primary
asset cannot legally or technically be downloaded without user interaction,
use the fallback"), the documented fallback — this poly.pizza model — was used
instead. If a maintainer later downloads the Sketchfab original through a
logged-in browser session, this README and `THIRD_PARTY_ASSETS.md` must be
updated to the primary asset's attribution.

## Package contents

The download is a single GLB (no archive, no scripts, no executables — binary
mesh + texture data only):

- 6 nodes / 6 meshes, one shared material (`ColourPalette`), 4,564 triangles:
  - `Body` (3,856 tris) — frame, arms, ducts, landing skids.
  - `Rotor_FL`, `Rotor_FR`, `Rotor_BL`, `Rotor_BR` (156 tris each) — **four
    separate rotor disc meshes**, so per-rotor spin animation is possible
    without editing the source.
  - `Cube.002` (84 tris) — underside camera.
- Texture maps: **one** embedded 128×128 PNG base-color palette
  (`ColorPalette`, extracted copy in `textures/ColorPalette.png` for
  inspection). The material is `metallicFactor = 0`, `roughnessFactor = 0.75`.
  The package contains **no** normal, metallic, roughness or emission maps —
  claims otherwise would be false. The supplied material is used as-is.
- Bounding box (model space): X −0.287…0.287, Y −0.159…0.048,
  Z −0.525…0.257 m → 0.574 × 0.208 × 0.781 m.

`drone_model.glb` is a byte-identical copy of the downloaded file (verified by
SHA-256 above); `source/` keeps the pristine original under its CDN name.

## Modifications made

None to the mesh, UVs or textures. All adaptations live in the Godot wrapper
scene, not in the source asset:

- **Scale**: uniform ×0.64 in the wrapper scene, so the model's length
  (0.781 m → 0.50 m) matches the logical collision-sphere diameter
  (`SimConfig.drone_radius * 2 = 0.5 m`).
- **Orientation**: the creator's named front (the `Rotor_FL`/`Rotor_FR` pair,
  +Z in model space) is rotated 180° about Y in the wrapper so it faces the
  simulator's forward axis (−Z). The model is Y-up already; no other axis fix
  is needed.
- **Origin/pivot**: model origin sits roughly at body centre; the wrapper
  aligns it to the logical drone position (collision-sphere centre).
- **Materials**: imported as-is (palette base-color texture, metallic 0,
  roughness 0.75). No material overrides are applied to the model. Per-agent
  identification uses a separate emissive marker mesh, not texture swaps.

## Texture-map list

| Map | Present | Details |
|---|---|---|
| Base color | yes | `ColorPalette`, 128×128 PNG, embedded in GLB |
| Normal | no | — |
| Metallic | no | factor 0 (constant) |
| Roughness | no | factor 0.75 (constant) |
| Emission | no | — |
| Height | no | — |

## Replacement guide

To swap in a different model: replace `drone_model.glb`, keep the node names
`Rotor_FL/FR/BL/BR` if you want rotor animation (otherwise the wrapper falls
back to a static model), update the scale/orientation notes above, and record
the new provenance here and in `THIRD_PARTY_ASSETS.md`.
