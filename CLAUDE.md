# Alchemy Prototype

2D alchemy simulation — emergent chemical reactions from property-based substance interactions.

## Tech Stack

- Godot 4.x, GDScript
- Web export as secondary target

## Project Layout

- `src/` — all game code (GDScript + scenes)
- `data/substances/` — substance definitions as `.tres` resource files
- `assets/` — sprites, shaders, audio
- `doc/` — project documentation (vision, notes)
- `docs/superpowers/specs/` — design specs

## Architecture

Three simulation systems (particle grid, fluid sim, rigid bodies) coordinated by a mediator. Six extensible fields (temperature, pressure, electricity, light, magnetism, sound) feed back into the simulation to produce emergent behavior.

See `docs/superpowers/specs/2026-04-05-alchemy-prototype-design.md` for full design spec.

## Conventions

- GDScript only — no C#/C++ unless performance demands it
- Substances are data (`.tres`), not code — add new substances by creating resource files
- Fields extend `field_base.gd` — pluggable architecture
- One class per file, one responsibility per class
- Keep scripts small and focused
- FPS overlay always visible, game log togglable, perf logging available
- **Never use `@warning_ignore`** — fix the root cause of every warning. Use explicit `float()` casts for integer division, rename parameters to avoid shadowing, remove truly unused parameters.

## Key Commands

```bash
# Run the project (from Godot editor or CLI)
godot --path . src/main.tscn
```
