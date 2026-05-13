# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Context

**COLLAB JAM '26** – a Godot 4.6 game jam project targeting Web (HTML5 + WebGL). Fast iteration is critical. Strict typing is enforced across the codebase to catch errors early and enable reliable refactoring during the jam.

- **Engine**: Godot 4.6 with gl_compatibility renderer
- **Target**: Web (exports to HTML5)
- **Genre**: 3D first-person auto-runner set in a Moscow metro (current map: `Scenes/Game/Maps/Metro1/metro_1.tscn`)
- **CI/CD**: GitHub Actions → itch.io deployment
- **Developers**: Mark & Arran

## Game Architecture

> Deep-dive references in `claude/reference/`:
> - [`character-controller.md`](claude/reference/character-controller.md) — `Player` / `Pawn` / `PawnCamera` / `CharacterVisual`
> - [`npc-ai.md`](claude/reference/npc-ai.md) — `NPCCharacter` + rail contract with `MetroMovement`

The player **does not move themselves**. `Scenes/Game/Maps/metro_movement.gd` (`MetroMovement`, a `@tool` `Node3D`) drives the player parametrically along a rail derived from a `NavigationRegion3D`. `Scenes/Player/player.gd` (`Player extends Pawn`) only handles **lane input, run-speed, headbob, mouse pitch, and the subway-shuffle dodge mechanic**.

Key consequences when editing player or NPC code:

- `Player` is a `CharacterBody3D` subclass via `Pawn` (`Scenes/Characters/pawn.gd` — the project-owned base for any rail-driven actor), but its `global_position` is **written by `MetroMovement`** every physics frame. Don't try to `move_and_slide()` from the player.
- Lanes are a fixed perpendicular offset to the rail: `LANE_OFFSETS = [-1.0, 0.0, 1.0]` (left, center, right). Both `Player` and `NPCCharacter` expose `get_current_lane()` so `MetroMovement` can place them.
- `NPCCharacter` (`Scenes/Characters/npc_character.gd`) runs on the same rail with two `RailDirection`s: `FORWARD` (parked greeters at finish) and `REVERSE` (oncoming traffic). `MetroMovement` registers every node in group `"npc"` on `_ready` and drives it.
- The "subway shuffle" is a bullet-time encounter: a forward `ShuffleCast` on the player triggers `start_subway_shuffle()`, which sets `Engine.time_scale = shuffle_time_scale` and waits on a held `left`/`right` action. Resolution compares world-space side vectors — same side = collision/knockdown.
- `MetroMovement._build_corners()` aggressively post-processes the raw nav path (axis-snap, center-on-corridor, merge close, orthogonalize). Editor button `refresh_debug` rebuilds debug spheres without entering play mode.
- Goal trigger: `Player.reach_goal()` is called by the level script and emits `goal_reached`; `Scenes/Game/Maps/Metro1/end_camera.gd` listens for the end cinematic.

Defined input actions (project.godot): `left`, `right`, plus `ui_cancel` for mouse-mode toggle. No `forward`/`back`/`jump`/`duck`/`crouch`/`sprint` — this is a runner, not a free-look character.

## Development Workflow

### Building & Exporting

`Taskfile.yml` wraps the common commands (requires [Task](https://taskfile.dev) + `godot` on PATH):

```bash
task run      # godot --path .
task edit     # godot --editor --path .
task build    # rm -rf build/web && godot --headless --export-release "Web" build/web/index.html
task deploy   # task build && butler push build/web smitner/igc-cj-26:html5
```

Or invoke Godot directly:
```bash
godot --headless --export-release "Web" build/web/index.html
```

> Note: `export_presets.cfg` configures `export_path="build/web/igc-cj-26.html"`, but every entry point (Taskfile, CI) overrides to `build/web/index.html` because itch.io expects `index.html` at the channel root. Don't "fix" the discrepancy.

Pushing to `main` triggers `.github/workflows/deploy.yml` → web export → Butler upload to `smitner/igc-cj-26:html5`. One other workflow exists and rarely fires: `docs.yml` (mkdocs — no `docs/` folder currently in repo, dormant).

### Project Structure

```
res://Assets/         – Images, audio, models (sub-folders TitleCase including Textures/)
res://Resources/      – Data files; Maps/ holds TrenchBroom .map sources
res://Scenes/         – .tscn files AND their per-component .gd scripts
res://Scripts/        – currently empty; scripts live next to scenes (see below)
res://Shaders/        – .gdshader files (cctv.gdshader)
res://addons/         – func_godot (TrenchBroom integration)
```

Folders are color-coded in the editor for quick navigation.

**Scripts are co-located with scenes**, not collected in `Scripts/`. Example: `Scenes/Player/player.gd` lives next to `Scenes/Player/Player.tscn`. The empty `Scripts/` folder is reserved for future utilities/autoloads if needed; per-component code stays beside its scene.

## Mapping (TrenchBroom + FuncGodot)

Levels are authored in TrenchBroom (`.map` files in `res://Resources/Maps/`) and built into Godot scenes at runtime / editor-time by the FuncGodot plugin.

**Texture folder is uppercase**: `res://Assets/Textures/<collection>/`. Follows the same TitleCase convention as sibling asset folders (`Audio`, `Models`).

### Per-machine setup (NOT committed — every contributor regenerates on first checkout)

These three artifacts live outside the repo because their paths differ per machine. Mark and Arran each set them up once on a fresh clone.

1. **TrenchBroom game config** → `<TB_user_data>/games/IGC CollabJam 26/` (Windows: `%APPDATA%\TrenchBroom\games\IGC CollabJam 26\`). Contains `GameConfig.cfg`, `FuncGodot.fgd`, `icon.png`.
   - Regenerate by clicking the **Export GameConfig** tool button on `res://addons/func_godot/game_config/trenchbroom/func_godot_tb_game_config.tres` in Godot's inspector.
2. **FuncGodot local config JSON** → `<godot_user_data>/COLLAB JAM '26/func_godot_config.json`. Holds FGD output folder, TrenchBroom game config folder, Map Editor Game Path.
   - Set the four fields in the inspector on `res://addons/func_godot/func_godot_local_config.tres`, then click **Export func_godot settings**. Requires running the project once first so Godot creates the `user://` directory.
   - **Map Editor Game Path** must point at `<your_clone>/Assets` (not project root, not `Assets/Textures`).
3. **TrenchBroom Game Path** → Preferences → Games → IGC CollabJam 26 → Game Path = `<your_clone>/Assets`.

### Daily mapping workflow

- **Add a texture**: drop `<name>.png|jpg` into `res://Assets/Textures/<collection>/`. In TB: View → Reload Material Collections. No `.tres` edits needed — FuncGodot generates a material on next map build.
- **Build a map in Godot**: add a `FuncGodotMap` node as a *child* of your scene root (never the root itself), set `Local Map File` to the `.map`, set `Map Settings` to `res://addons/func_godot/func_godot_default_map_settings.tres`, click **Build** in the inspector.
- **Gameplay nodes (camera, lights, controllers)** must be **siblings** of `FuncGodotMap`, not children — FuncGodotMap frees all its children on rebuild.
- **Map format**: Valve 220 (set when creating new maps in TB). Standard format works but loses UV control.

## Strict Typing

Configured in `project.godot` (`[debug]` section). The hard errors:
- `untyped_declaration = 2` (error) — every `var` needs a type annotation
- `unsafe_property_access`, `unsafe_method_access`, `unsafe_cast`, `unsafe_call_argument`, `unsafe_void_return` all = 2 (error) — no untyped property/method access on `Variant`
- `inferred_declaration = 1` (warning) — `var x := foo()` is allowed but flagged; prefer explicit types

```gdscript
# ✅ GOOD – explicit types, caught by LSP
var velocity: Vector3 = Vector3.ZERO
var speed: float = 100.0
func damage(amount: int) -> void:
    health -= amount

# ❌ BAD – triggers compile-time error
var velocity                      # untyped_declaration error
func damage(amount):              # unsafe_call_argument + missing return type
    pass

# ⚠️  WARNING ONLY – allowed but flagged
var velocity := Vector3.ZERO      # inferred_declaration; prefer explicit type
```

**Why this matters for jam speed:**
- LSP catches typos and type mismatches before you test
- Refactoring is safe; editor warns if you break a signature
- Less runtime debugging, more building
- No silent type coercion bugs

### Exporting Variables

Use `@export` for editor properties:

```gdscript
extends Node3D

@export var speed: float = 100.0
@export var colors: Array[Color] = [Color.RED, Color.BLUE]
@export var enemy_scene: PackedScene
@export_range(0.0, 1.0, 0.01) var shuffle_time_scale: float = 0.2  # @export_range/@export_group used heavily on Player
```

This exposes variables to the editor inspector, enabling rapid iteration without code changes.

## Type Checking & Validation

Godot 4.6 enforces strict typing via the built-in type checker. All code must:
- Declare variable types explicitly (no inferred types)
- Provide return types on functions (including `-> void`)
- Use proper typed containers (`Array[Type]`, `Dictionary[K, V]`)
- Handle unsafe operations (property access, method calls, casts)

**The type checker is strict by design.** This catches bugs early and makes refactoring safe. All GDScript written must pass the type checker with no warnings.

## File Organization

**Scripts per-component:** one file per scene/class. Convention in this repo:
- Scene file: `PascalCase.tscn` (e.g. `Player.tscn`, `NPCCharacter.tscn`)
- Script file: `snake_case.gd` with a matching `class_name PascalCase` (e.g. `player.gd` → `class_name Player`)
- Both live in the same folder under `Scenes/` (or `Scenes/<Group>/`).

```
Scenes/Player/
├── Player.tscn
└── player.gd       (class_name Player extends Pawn)
Scenes/Characters/
├── NPCCharacter.tscn
└── npc_character.gd (class_name NPCCharacter extends CharacterBody3D)
```

**Singletons (autoload):** none currently registered. Keep minimal — add via Project Settings → Autoload only when shared global state is unavoidable.

## Git & CI

- **Main branch is auto-deployed**: any push to main triggers GitHub Actions → Web export → itch.io upload. Keep main deployable.
- Work on feature branches; merge to main when ready for release.
- Commit frequently during jam; clear messages help track what changed.

## Key Gdscript Patterns

### Signals for Communication

```gdscript
signal player_died

func _ready() -> void:
    player_died.connect(_on_player_died)

func die() -> void:
    player_died.emit()

func _on_player_died() -> void:
    print("Game Over")
```

### Typed Arrays & Dictionaries

```gdscript
var enemies: Array[Node3D]
var enemy_data: Dictionary[String, int] = {
    "health": 100,
    "damage": 10
}
```

### Constants & Enums

```gdscript
const TILE_SIZE: int = 16
const GRAVITY: float = 9.8

enum STATE { IDLE, RUNNING, JUMPING }
var current_state: STATE = STATE.IDLE
```

## Performance Notes

- **3D, not 2D**: every body in this project is `CharacterBody3D` / `RigidBody3D` / `StaticBody3D`. There is no 2D gameplay layer.
- **Culling**: Godot handles spatial culling; don't over-optimize early.
- **Physics**: rail-driven nodes (player, NPCs) write `global_position` directly — they do not call `move_and_slide()`. New gameplay bodies that *do* need physics should use `CharacterBody3D` or `RigidBody3D`.
- **Draw calls**: Batching is automatic; avoid excessive node nesting.
- **Shaders**: gl_compatibility renderer supports most GLSL; **avoid compute shaders** (unsupported on this renderer / Web target).

## Deployment

itch.io deployment is automatic on `main` branch push. The build:
1. Exports Web preset
2. Runs Butler to upload to `smitner/igc-cj-26`
3. Updates the HTML5 build channel

To test export locally:
```bash
godot --headless --export-release "Web" build/web/index.html
# Check build/web/index.html in a browser
```

## External Dependencies

One vendored addon — load-bearing, do not remove:

- **`addons/func_godot/`** — TrenchBroom `.map` → Godot scene compiler. See the *Mapping* section above.

Character controller is project-owned: `Scenes/Characters/pawn.gd` (base) + `Scenes/Characters/pawn_camera.gd` (rig) + per-actor scripts (`Scenes/Player/player.gd`, `Scenes/Characters/npc_character.gd`).

Beyond `func_godot`, avoid third-party plugins during the jam unless critical. External asset packs (art, audio — see `CREDITS.md`) are fine.

This keeps builds fast and export size reasonable for Web.
