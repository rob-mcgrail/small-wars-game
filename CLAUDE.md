# Claude Code Instructions

## GDScript 4.6 Pitfalls - CHECK BEFORE COMMITTING

These are recurring mistakes. Review every change against this list.

### 1. Duplicate variable declarations in the same scope
GDScript does not allow re-declaring a variable with `var` in the same function scope, even in a nested block. If a variable is declared at the top of a function, you CANNOT declare it again inside an `if` block.

**Wrong:**
```gdscript
func foo():
    var weapon_type: String = "rifle"
    if condition:
        var weapon_type: String = "atgm"  # ERROR: duplicate
```

**Right:**
```gdscript
func foo():
    var weapon_type: String = "rifle"
    if condition:
        weapon_type = "atgm"  # just reassign
```

### 2. No inline ternary with +=
GDScript does NOT support Python-style `x += 1 if cond else 0`. Use an explicit if block.

**Wrong:**
```gdscript
result["crew_killed"] += 1 if randf() < 0.3 else 0
```

**Right:**
```gdscript
if randf() < 0.3:
    result["crew_killed"] += 1
```

### 3. Type inference from Variant
Using `:=` to assign from a Dictionary/Array access fails because the type is Variant. Always use explicit types.

**Wrong:**
```gdscript
var code := terrain_grid[row][col]
```

**Right:**
```gdscript
var code: String = terrain_grid[row][col]
```

### 4. YAML parser limitations
Our custom YAML parser has specific limitations:
- `|` and `>` multiline blocks are supported (we fixed this)
- Inline arrays `[1, 2, 3]` are supported (we fixed this)
- Inline dicts `{key: value}` are NOT supported - use nested YAML instead
- Comments with `#` are supported
- `[]` and `{}` as empty values are supported

### 5. Always test with `godot --headless` AND `godot --run`
The headless test sometimes passes when the GUI version fails, particularly for:
- Variable scope issues that only trigger when specific code paths execute
- Class registration issues with the .godot cache

When in doubt, delete `.godot/` and reimport: `godot --headless --import`

### 6. Web builds require explicit file inclusion
YAML files are not Godot resources. The export preset must include `*.yaml` in `include_filter`. The `conflicts/manifest.yaml` is required for web builds because `DirAccess` directory scanning doesn't work reliably on web.

## Project Structure
- `conflicts/` - scenario content (weapons, factions, scenarios with maps)
- `config/` - global game settings (terrain, game.yaml, units.yaml for sandbox)
- `scripts/` - all GDScript code
- `scenes/` - Godot scene files
- `tests/` - test scripts (run with `godot --headless --script tests/test_runner.gd`)
- `build/` - web export output (gitignored)

## Architecture
- `hex_map.gd` - coordinator: UI, input, drawing, fog of war
- `combat_resolver.gd` - combat ticks, morale, destruction, pursuit
- `combat.gd` - individual shot resolution
- `movement.gd` - unit movement, pathfinding
- `hq_comms.gd` - HQ communications
- `order_manager.gd` - order C2 delays with faction-based config
- `hex_grid.gd` - hex geometry, LOS
- `scenario_loader.gd` - loads conflict/faction/scenario hierarchy
- `order.gd` - Order data model (TRANSMITTING -> PLANNING -> EXECUTING)
- `game_clock.gd` - simple play/pause time
