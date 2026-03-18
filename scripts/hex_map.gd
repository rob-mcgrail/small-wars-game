extends Node2D

# Set before adding to scene tree
var map_file: String = ""
var scenario_file: String = ""

# Scenario state
var scenario_loader: ScenarioLoader = null
var reinforcements_spawned: Dictionary = {}  # int index -> true
var scenario_ended: bool = false
var enemy_ai_accum: float = 0.0
const ENEMY_AI_INTERVAL: float = 15.0  # game minutes between AI updates
var victory_panel: CanvasLayer = null

# Map data
var hex_size: float
var hex_width: float
var hex_height: float
var map_cols: int
var map_rows: int
var terrain_grid: Array = []   # [row][col] -> String code
var elevation_grid: Array = [] # [row][col] -> int 0-9

# Terrain type lookup: code -> {name, color, speed_modifier}
var terrain_types: Dictionary = {}

# Unit type lookup: code -> {name, description, icon_color, symbol, speed, attack, defense, spotting_range}
var unit_types: Dictionary = {}

# Units on the map: Array of {type_code, col, row, name}
var units: Array = []

# Elevation shading
var elev_min_shade: float
var elev_max_shade: float

var selected_hex := Vector2i(-1, -1)
var hovered_hex := Vector2i(-1, -1)

# LOS cache: set of visible hex coords for the currently selected unit
var los_visible: Dictionary = {}  # Vector2i -> true
var selected_unit: Dictionary = {}

# Current movement posture and ROE for new orders
var current_posture: Order.Posture = Order.Posture.NORMAL
var current_roe: Order.ROE = Order.ROE.RETURN_FIRE
var current_pursuit: Order.Pursuit = Order.Pursuit.HOLD

# Cached posture configs
var posture_configs: Dictionary = {}

# Camera
var camera_offset := Vector2.ZERO
var is_panning := false
var zoom_level := 1.0
const ZOOM_MIN := 0.2
const ZOOM_MAX := 3.0
const ZOOM_STEP := 0.15


# ROE multipliers on weapon's rate_of_fire
# e.g. a 600 RPM DShK on Fire at Will fires at 3.5% = ~20 RPM (realistic burst fire)
const ROE_RATE_FIRE_AT_WILL: float = 0.035      # sustained suppressive fire
const ROE_RATE_RETURN_FIRE: float = 0.015       # reactive bursts
const ROE_RATE_HALT_AND_ENGAGE: float = 0.05    # heavy focused engagement

# Morale thresholds
const MORALE_BREAK_THRESHOLD: int = 30
const MORALE_ROUT_THRESHOLD: int = 15

# Selection highlight
const COLOR_SELECT_OUTLINE := Color(0.7, 0.3, 0.9, 0.9)
const COLOR_HOVER_OUTLINE := Color(1.0, 1.0, 1.0, 0.5)

# UI
var info_label: Label
var unit_panel: UnitPanel
var game_clock: GameClock
var game_flow_panel: GameFlowPanel
var order_manager: OrderManager
var combat: Combat
var hex_grid: HexGrid
var combat_resolver: CombatResolver
var movement: Movement
var hq_comms: HQComms

# Display toggles
var show_los := true
var show_comms := true
var show_weapon_ranges := true
var show_units := true
var show_elevation := false
var show_move_cost := false
var display_bar: CanvasLayer

# Unit carousel
var carousel_label: Label
var carousel_left_btn: Button
var carousel_right_btn: Button
var carousel_order: Array = []  # sorted unit list
var carousel_index: int = 0

# Context menu
var context_menu: PopupMenu
var context_menu_unit: Dictionary = {}
var current_order_mode: Order.Type = Order.Type.MOVE  # MOVE, PATROL, or AMBUSH
var current_speed: int = 2  # 1=slow, 2=normal, 3=fast, 4=very fast
const SPEED_VALUES := [0.0, 4.0, 2.0, 0.5, 0.1]  # index 0 unused, 1-4 = seconds per game minute

# HQ config (loaded from game.yaml)
var hq_switching_cost: float = 15.0
var hq_comms_order_buff: float = 0.8
var hq_los_order_buff: float = 0.6
var hq_los_morale_buff: int = 5
var hq_los_accuracy_buff: float = 1.1
var hq_los_suppression_resistance: float = 0.85

var hq_auto_switch_minutes: float = 10.0

# Night config
var sunrise_hour: int = 6
var sunset_hour: int = 19
var night_spotting_modifier: float = 0.3
var night_accuracy_modifier: float = 0.4
var night_range_modifier: float = 0.5

# Destruction effects config
var destruction_marker_duration: float = 60.0
var destruction_direct_hq_shock: int = 15
var destruction_parent_hq_shock: int = 8
var destruction_los_witness_shock: int = 10

# Death markers: Vector2i -> float (game time of death)
var death_markers: Dictionary = {}

# Fog of war
# Fog of war mode: "full_knowledge", "satellite", "approximate", "total"
var fog_of_war_mode: String = "approximate"
var satellite_range: int = 6
var revealed_hexes: Dictionary = {}  # Vector2i -> true (terrain visible)
var elevation_revealed: Dictionary = {}  # Vector2i -> true (elevation number visible)
var spotted_enemies: Dictionary = {}  # unit name -> Vector2i (current spotted position)
var last_seen_enemies: Dictionary = {}  # Vector2i -> float (game_time when enemy was last seen there)
const LAST_SEEN_DURATION: float = 30.0  # minutes before last-seen marker fades

# Visual combat effects
# Array of {from: Vector2i, to: Vector2i, time_remaining: float, hit: bool}
var fire_effects: Array = []
const FIRE_EFFECT_DURATION := 2.0  # seconds (real time)

# Performance throttling
var _redraw_counter: int = 0
var _log_counter: int = 0

# Terrain LOS preview (Cmd+Click on empty hex)
var terrain_los_preview: Dictionary = {}  # Vector2i -> true
var terrain_los_origin: Vector2i = Vector2i(-1, -1)
const TERRAIN_LOS_RANGE: int = 6  # 3km = 6 hexes


func _ready() -> void:
	_load_terrain_types()
	_load_unit_types()
	_load_display_config()
	_load_hq_config()

	# Scenario loading: set map_file from scenario, then load map normally
	if scenario_file != "":
		scenario_loader = ScenarioLoader.new()
		if scenario_loader.load_scenario(scenario_file):
			map_file = scenario_loader.map_path
		else:
			push_error("hex_map: Failed to load scenario %s" % scenario_file)
			scenario_loader = null

	_load_map()
	hex_grid = HexGrid.new(terrain_grid, elevation_grid, map_cols, map_rows, hex_size)

	if scenario_loader != null:
		_load_scenario_forces(scenario_loader)
	else:
		_place_starting_units()

	_setup_unit_panel()
	_setup_game_flow()

	# Override clock and day/night from scenario
	if scenario_loader != null:
		game_clock.game_time_minutes = float(scenario_loader.start_hour) * 60.0 + float(scenario_loader.start_minute)
		if scenario_loader.sunrise_hour >= 0:
			sunrise_hour = scenario_loader.sunrise_hour
			combat_resolver.sunrise_hour = sunrise_hour
			hq_comms.sunrise_hour = sunrise_hour
			game_flow_panel.sunrise = sunrise_hour
		if scenario_loader.sunset_hour >= 0:
			sunset_hour = scenario_loader.sunset_hour
			combat_resolver.sunset_hour = sunset_hour
			hq_comms.sunset_hour = sunset_hour
			game_flow_panel.sunset = sunset_hour

	# Apply scenario overrides to game systems
	if scenario_loader != null and not scenario_loader.overrides.is_empty():
		_apply_scenario_overrides(scenario_loader.overrides)

	# Load faction C2 configs into order manager
	if scenario_loader != null:
		var player_c2 = scenario_loader.player_faction.get("c2", {})
		if player_c2 is Dictionary and not player_c2.is_empty():
			order_manager.player_c2 = player_c2
		var enemy_c2 = scenario_loader.enemy_faction.get("c2", {})
		if enemy_c2 is Dictionary and not enemy_c2.is_empty():
			order_manager.enemy_c2 = enemy_c2

	# Set fog of war mode from player faction
	if scenario_loader != null and not scenario_loader.player_faction.is_empty():
		fog_of_war_mode = str(scenario_loader.player_faction.get("fog_of_war", "approximate"))
		satellite_range = int(scenario_loader.player_faction.get("satellite_range", 6))
		_init_fog_of_war()
	elif scenario_loader != null:
		# Faction not loaded but scenario exists - try loading fog from overrides
		_init_fog_of_war()

	_setup_display_bar()  # Also creates info_label
	# Run one tick to initialize all systems (comms, morale, LOS, etc.)
	_on_time_advanced(0.0)
	# Select and center on Battalion HQ at start
	var found_hq := false
	for unit in units:
		if unit.get("side", "player") == "player":
			var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
			if utype.get("is_hq", false) and int(utype.get("hq_level", 0)) == 1:
				_select_and_center_unit(unit)
				found_hq = true
				break
	if not found_hq:
		camera_offset = Vector2(-100, -50)


func _load_hq_config() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/game.yaml")
	hq_switching_cost = cfg.get_float("hq.switching_cost_minutes", 15.0)
	hq_comms_order_buff = cfg.get_float("hq.comms_order_buff", 0.8)
	hq_los_order_buff = cfg.get_float("hq.los_order_buff", 0.6)
	hq_los_morale_buff = cfg.get_int("hq.los_morale_buff", 5)
	hq_los_accuracy_buff = cfg.get_float("hq.los_accuracy_buff", 1.1)
	hq_los_suppression_resistance = cfg.get_float("hq.los_suppression_resistance", 0.85)

	hq_auto_switch_minutes = cfg.get_float("hq.auto_switch_minutes", 10.0)

	# Night config
	sunrise_hour = cfg.get_int("time.sunrise_hour", 6)
	sunset_hour = cfg.get_int("time.sunset_hour", 19)
	night_spotting_modifier = cfg.get_float("night.spotting_range_modifier", 0.3)
	night_accuracy_modifier = cfg.get_float("night.accuracy_modifier", 0.4)
	night_range_modifier = cfg.get_float("night.effective_range_modifier", 0.5)

	# Destruction effects
	destruction_marker_duration = cfg.get_float("destruction.marker_duration_minutes", 60.0)
	destruction_direct_hq_shock = cfg.get_int("destruction.direct_hq_morale_shock", 15)
	destruction_parent_hq_shock = cfg.get_int("destruction.parent_hq_morale_shock", 8)
	destruction_los_witness_shock = cfg.get_int("destruction.los_witness_morale_shock", 10)


func _is_night() -> bool:
	var hour: int = (int(game_clock.game_time_minutes) / 60) % 24
	return hour < sunrise_hour or hour >= sunset_hour


func _unit_has_night_vision(unit: Dictionary) -> bool:
	var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
	return utype.get("night_vision", false)


func _load_terrain_types() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/terrain.yaml")

	elev_min_shade = cfg.get_float("elevation.min_shade", -0.15)
	elev_max_shade = cfg.get_float("elevation.max_shade", 0.15)

	var types = cfg.get_value("terrain_types", [])
	for t in types:
		var code: String = t.get("code", "?")
		terrain_types[code] = {
			"name": t.get("name", "unknown"),
			"color": Color(t.get("color", "#ffffff")),
			"speed_modifier": float(t.get("speed_modifier", 1.0)),
		}


func _load_unit_types() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/units.yaml")
	var types = cfg.get_value("unit_types", [])
	for t in types:
		var code: String = t.get("code", "?")
		unit_types[code] = t
		# Ensure parsed color
		unit_types[code]["icon_color"] = Color(t.get("icon_color", "#ffffff"))


func _place_starting_units() -> void:
	if terrain_grid.is_empty():
		return
	# Place player technical near the center
	var center_col := map_cols / 2
	var center_row := map_rows / 2
	var player_pos: Vector2i = hex_grid.find_open_hex_near(center_col, center_row)
	if player_pos != Vector2i(-1, -1):
		var unit_dict: Dictionary = {
			"type_code": "TEC",
			"col": player_pos.x,
			"row": player_pos.y,
			"name": "Technical 1",
			"side": "player",
		}
		_init_unit_ammo_and_morale(unit_dict)
		units.append(unit_dict)

	# Place player Technical 2 nearby
	var player2_pos: Vector2i = hex_grid.find_open_hex_near(center_col, center_row + 2)
	if player2_pos != Vector2i(-1, -1):
		var unit2_dict: Dictionary = {
			"type_code": "TEC",
			"col": player2_pos.x,
			"row": player2_pos.y,
			"name": "Technical 2",
			"side": "player",
		}
		_init_unit_ammo_and_morale(unit2_dict)
		units.append(unit2_dict)

	# Place enemy technicals ~8km (16 hexes) away
	var enemy_pos: Vector2i = hex_grid.find_open_hex_near(center_col + 16, center_row)
	if enemy_pos != Vector2i(-1, -1):
		var enemy_dict: Dictionary = {
			"type_code": "TEC",
			"col": enemy_pos.x,
			"row": enemy_pos.y,
			"name": "Enemy Technical 1",
			"side": "enemy",
			"default_roe": "fire at will",
		}
		_init_unit_ammo_and_morale(enemy_dict)
		units.append(enemy_dict)

	var enemy2_pos: Vector2i = hex_grid.find_open_hex_near(center_col + 16, center_row + 2)
	if enemy2_pos != Vector2i(-1, -1):
		var enemy2_dict: Dictionary = {
			"type_code": "TEC",
			"col": enemy2_pos.x,
			"row": enemy2_pos.y,
			"name": "Enemy Technical 2",
			"side": "enemy",
			"default_roe": "fire at will",
		}
		_init_unit_ammo_and_morale(enemy2_dict)
		units.append(enemy2_dict)

	# Place Battalion HQ 6 hexes behind center
	var bhq_pos: Vector2i = hex_grid.find_open_hex_near(center_col - 6, center_row)
	if bhq_pos != Vector2i(-1, -1):
		var bhq_dict: Dictionary = {
			"type_code": "BHQ",
			"col": bhq_pos.x,
			"row": bhq_pos.y,
			"name": "Battalion HQ",
			"side": "player",
		}
		_init_unit_ammo_and_morale(bhq_dict)
		units.append(bhq_dict)

	# Place Company HQ 3 hexes behind center
	var shq_pos: Vector2i = hex_grid.find_open_hex_near(center_col - 3, center_row)
	if shq_pos != Vector2i(-1, -1):
		var shq_dict: Dictionary = {
			"type_code": "SHQ",
			"col": shq_pos.x,
			"row": shq_pos.y,
			"name": "Company HQ",
			"side": "player",
		}
		_init_unit_ammo_and_morale(shq_dict)
		shq_dict["assigned_hq"] = "Battalion HQ"
		units.append(shq_dict)

	# Set technicals' assigned HQ
	for u in units:
		if u.get("name", "") == "Technical 1" or u.get("name", "") == "Technical 2":
			u["assigned_hq"] = "Company HQ"



func _init_unit_ammo_and_morale(unit: Dictionary) -> void:
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var weapons: Array = utype.get("weapons", [])
	var ammo_array: Array = []
	for w in weapons:
		ammo_array.append(int(w.get("ammo", 0)))
	unit["current_ammo"] = ammo_array
	unit["current_morale"] = int(utype.get("morale", 50))
	unit["current_crew"] = int(utype.get("crew", 4))
	unit["vehicle_damage"] = 0.0  # 0.0 = pristine, 1.0+ = destroyed
	unit["mobility_damage"] = 0.0  # 0.0 = fine, 1.0+ = IMMOBILISED
	unit["unit_status"] = ""  # "", "BROKEN", "ROUTING", "DESTROYED", "IMMOBILISED"
	unit["morale_recovery_accum"] = 0.0  # fractional morale recovery accumulator
	unit["morale_damage"] = 0  # permanent morale reduction from trauma
	unit["assigned_hq"] = ""
	unit["in_comms"] = false
	unit["in_hq_los"] = false
	unit["hq_switch_remaining"] = 0.0


func _apply_scenario_overrides(overrides: Dictionary) -> void:
	# Night overrides (per-side)
	var night_ov = overrides.get("night", {})
	if night_ov is Dictionary:
		if "player_spotting_modifier" in night_ov:
			combat_resolver.night_spotting_modifier = float(night_ov["player_spotting_modifier"])
		if "player_accuracy_modifier" in night_ov:
			combat_resolver.night_accuracy_modifier = float(night_ov["player_accuracy_modifier"])
		if "player_range_modifier" in night_ov:
			combat_resolver.night_range_modifier = float(night_ov["player_range_modifier"])
		# Enemy night modifiers stored separately
		if "enemy_spotting_modifier" in night_ov:
			combat_resolver.enemy_night_spotting_modifier = float(night_ov["enemy_spotting_modifier"])
		if "enemy_accuracy_modifier" in night_ov:
			combat_resolver.enemy_night_accuracy_modifier = float(night_ov["enemy_accuracy_modifier"])
		if "enemy_range_modifier" in night_ov:
			combat_resolver.enemy_night_range_modifier = float(night_ov["enemy_range_modifier"])

	# Note: HQ/C2 overrides are now handled via faction c2 config in order_manager


func _load_scenario_forces(loader: ScenarioLoader) -> void:
	## Register scenario templates as unit types and spawn all units.
	if terrain_grid.is_empty():
		return

	# Register each resolved template as a unit type (merges into global dict)
	for template_key in loader.templates:
		var resolved: Dictionary = loader.get_resolved_template(template_key)
		if resolved.is_empty():
			continue
		# Use the template key as the type code
		resolved["code"] = template_key
		# Parse icon_color to Color
		resolved["icon_color"] = Color(resolved.get("icon_color", "#ffffff"))
		unit_types[template_key] = resolved

	# Spawn player forces
	for entry in loader.player_forces:
		_spawn_scenario_unit(entry, "player")

	# Spawn enemy forces
	for entry in loader.enemy_forces:
		_spawn_scenario_unit(entry, "enemy")

	# Resolve HQ assignments after all units exist
	_resolve_hq_assignments()


func _spawn_scenario_unit(entry: Dictionary, default_side: String) -> Dictionary:
	## Create a single unit from a scenario force entry.
	## Supports both template-based (new) and type-based (legacy) entries.
	var type_code: String = ""
	if entry.has("template"):
		type_code = str(entry.get("template", ""))
	else:
		type_code = str(entry.get("type", "TEC"))

	var hex_arr = entry.get("hex", [0, 0])
	var col: int = int(hex_arr[0]) if hex_arr is Array and hex_arr.size() > 0 else 0
	var row: int = int(hex_arr[1]) if hex_arr is Array and hex_arr.size() > 1 else 0

	# Clamp to map bounds
	col = clampi(col, 0, map_cols - 1)
	row = clampi(row, 0, map_rows - 1)

	var unit_name: String = str(entry.get("name", "%s_%d" % [type_code, units.size()]))
	var side: String = str(entry.get("side", default_side))

	var unit_dict: Dictionary = {
		"type_code": type_code,
		"col": col,
		"row": row,
		"name": unit_name,
		"side": side,
	}

	# Set default ROE if specified
	var default_roe: String = str(entry.get("default_roe", ""))
	if default_roe != "":
		unit_dict["default_roe"] = default_roe

	_init_unit_ammo_and_morale(unit_dict)

	# Override assigned_hq from scenario if specified
	var assigned_hq: String = str(entry.get("assigned_hq", ""))
	if assigned_hq != "":
		unit_dict["assigned_hq"] = assigned_hq

	units.append(unit_dict)
	return unit_dict


func _resolve_hq_assignments() -> void:
	## For units without an assigned HQ, try to find an appropriate one.
	## HQ units at level 2 (company) get assigned to the nearest level 1 (battalion) HQ.
	## Non-HQ units without assignment get the nearest company HQ of their side.
	var hq_units: Array = []
	for unit in units:
		var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
		if utype.get("is_hq", false):
			hq_units.append(unit)

	for unit in units:
		if unit.get("assigned_hq", "") != "":
			continue
		var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
		if utype.get("is_hq", false):
			var my_level: int = int(utype.get("hq_level", 0))
			if my_level >= 2:
				# Company/section HQ -> assign to nearest battalion HQ
				_assign_nearest_hq(unit, hq_units, 1)
		else:
			# Regular unit -> assign to nearest company HQ of same side
			_assign_nearest_hq(unit, hq_units, 2)


func _assign_nearest_hq(unit: Dictionary, hq_units: Array, target_level: int) -> void:
	var side: String = unit.get("side", "player")
	var best_name: String = ""
	var best_dist: float = INF
	var unit_pos := Vector2(unit.get("col", 0), unit.get("row", 0))

	for hq in hq_units:
		if hq.get("side", "player") != side:
			continue
		var hq_type: Dictionary = unit_types.get(hq.get("type_code", ""), {})
		var hq_level: int = int(hq_type.get("hq_level", 0))
		if hq_level != target_level:
			continue
		var hq_pos := Vector2(hq.get("col", 0), hq.get("row", 0))
		var dist: float = unit_pos.distance_to(hq_pos)
		if dist < best_dist:
			best_dist = dist
			best_name = hq.get("name", "")

	if best_name != "":
		unit["assigned_hq"] = best_name


func _check_reinforcements() -> void:
	## Spawn reinforcement waves when their time has arrived.
	if scenario_loader == null:
		return
	var current_hour: int = (int(game_clock.game_time_minutes) / 60) % 24
	var current_minute: int = int(game_clock.game_time_minutes) % 60

	for i in range(scenario_loader.reinforcements.size()):
		if i in reinforcements_spawned:
			continue
		var rf: Dictionary = scenario_loader.reinforcements[i]
		var rf_hour: int = int(rf.get("time_hour", 0))
		var rf_minute: int = int(rf.get("time_minute", 0))

		# Convert to minutes-since-midnight for comparison
		var rf_time: int = rf_hour * 60 + rf_minute
		var cur_time: int = current_hour * 60 + current_minute

		# Handle day wrap: if scenario starts at 18:00 and reinforcement is at 06:00,
		# we need the game_time_minutes to have actually reached that point
		var game_minutes_for_rf: float = 0.0
		var start_minutes: float = float(scenario_loader.start_hour) * 60.0 + float(scenario_loader.start_minute)
		if rf_time >= int(start_minutes):
			game_minutes_for_rf = float(rf_time)
		else:
			# Next day
			game_minutes_for_rf = float(rf_time) + 1440.0

		if game_clock.game_time_minutes >= game_minutes_for_rf:
			reinforcements_spawned[i] = true
			var side: String = str(rf.get("side", "enemy"))
			var rf_units = rf.get("units", [])
			if rf_units is Array:
				for entry in rf_units:
					_spawn_scenario_unit(entry, side)
			# Re-resolve HQ assignments for new units
			_resolve_hq_assignments()


func _check_victory_conditions() -> void:
	## Check scenario victory/defeat conditions each tick.
	if scenario_loader == null or scenario_ended:
		return
	# Don't check victory on the first tick (game hasn't started yet)
	var start_time: float = float(scenario_loader.start_hour) * 60.0 + float(scenario_loader.start_minute)
	if game_clock.game_time_minutes <= start_time:
		return

	var victory_data: Dictionary = scenario_loader.victory

	# Check defeat condition first (enemy crossing the line)
	var defeat: Dictionary = victory_data.get("defeat", {})
	if not defeat.is_empty():
		if _evaluate_condition(defeat, true):
			_end_scenario(false, defeat.get("description", "Defeat"))
			return

	# Check primary victory: hold_line means we win when the timer expires without defeat
	var primary: Dictionary = victory_data.get("primary", {})
	if not primary.is_empty():
		var primary_type: String = str(primary.get("type", ""))
		if primary_type == "hold_line":
			var until_hour: int = int(primary.get("until_hour", 24))
			var until_minute: int = int(primary.get("until_minute", 0))
			var until_time: float = float(until_hour) * 60.0 + float(until_minute)
			# Handle day wrap
			var start_minutes: float = float(scenario_loader.start_hour) * 60.0 + float(scenario_loader.start_minute)
			if until_time <= start_minutes:
				until_time += 1440.0
			if game_clock.game_time_minutes >= until_time:
				_end_scenario(true, primary.get("description", "Victory"))
				return

	# Check time limit
	var time_limit: float = float(victory_data.get("time_limit_hours", 0))
	if time_limit > 0:
		var start_minutes: float = float(scenario_loader.start_hour) * 60.0 + float(scenario_loader.start_minute)
		var end_time: float = start_minutes + time_limit * 60.0
		if game_clock.game_time_minutes >= end_time:
			# Time's up - check if defeat condition is met, otherwise victory
			if not defeat.is_empty() and _evaluate_condition(defeat, true):
				_end_scenario(false, defeat.get("description", "Defeat"))
			else:
				_end_scenario(true, primary.get("description", "Victory - time expired"))
			return


func _evaluate_condition(condition: Dictionary, is_defeat: bool) -> bool:
	## Evaluate a single victory/defeat condition.
	var cond_type: String = str(condition.get("type", ""))
	match cond_type:
		"line_crossed":
			return _check_line_crossed(condition)
		"hold_line":
			# hold_line as defeat: true if any matching unit crossed
			return _check_line_crossed(condition)
		"destroy_count":
			return _check_destroy_count(condition)
		"survive_all":
			return _check_survive_all(condition)
	return false


func _check_line_crossed(condition: Dictionary) -> bool:
	## Check if any unit matching the filter has crossed the specified row.
	var target_row: int = int(condition.get("row", 0))
	var unit_filter: String = str(condition.get("unit_filter", ""))
	var side: String = str(condition.get("side", "enemy"))

	for unit in units:
		if unit.get("unit_status", "") == "DESTROYED":
			continue
		if unit.get("side", "player") != side:
			continue
		if not _unit_matches_filter(unit, unit_filter):
			continue
		# "Crossed" means the unit's row is <= the target row (advancing north = decreasing row)
		if int(unit.get("row", 999)) <= target_row:
			return true
	return false


func _check_destroy_count(condition: Dictionary) -> bool:
	## Check if enough units of the specified side have been destroyed.
	var target_count: int = int(condition.get("count", 0))
	var side: String = str(condition.get("side", "enemy"))
	var destroyed: int = 0
	for unit in units:
		if unit.get("side", "player") != side:
			continue
		if unit.get("unit_status", "") == "DESTROYED":
			destroyed += 1
	return destroyed >= target_count


func _check_survive_all(condition: Dictionary) -> bool:
	## Check if all matching units are still alive. Returns true if ALL survive.
	var unit_filter: String = str(condition.get("unit_filter", ""))
	var side: String = str(condition.get("side", "player"))
	for unit in units:
		if unit.get("side", "player") != side:
			continue
		if not _unit_matches_filter(unit, unit_filter):
			continue
		if unit.get("unit_status", "") == "DESTROYED":
			return false
	return true


func _unit_matches_filter(unit: Dictionary, filter_name: String) -> bool:
	## Check if a unit matches a named filter from scenario conditions.
	if filter_name == "":
		return true
	var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
	match filter_name:
		"armored":
			return utype.get("is_armored", false)
		"is_hq":
			return utype.get("is_hq", false)
		"infantry":
			return not utype.get("is_armored", false) and not utype.get("is_hq", false)
	# Fallback: check if the filter matches the type code
	return unit.get("type_code", "") == filter_name


func _end_scenario(is_victory: bool, description: String) -> void:
	scenario_ended = true
	game_clock.paused = true
	game_flow_panel.set_paused(true)

	# Evaluate bonus objectives
	var bonuses_achieved: Array[String] = []
	var total_bonus_points: int = 0
	if scenario_loader != null:
		var bonus_list = scenario_loader.victory.get("bonus", [])
		if bonus_list is Array:
			for bonus in bonus_list:
				var achieved := false
				var bonus_type: String = str(bonus.get("type", ""))
				match bonus_type:
					"destroy_count":
						achieved = _check_destroy_count(bonus)
					"survive_all":
						achieved = _check_survive_all(bonus)
				if achieved:
					var pts: int = int(bonus.get("points", 0))
					total_bonus_points += pts
					bonuses_achieved.append("%s (+%d)" % [str(bonus.get("description", "")), pts])

	_show_victory_panel(is_victory, description, bonuses_achieved, total_bonus_points)


func _show_victory_panel(is_victory: bool, description: String, bonuses: Array[String], bonus_points: int) -> void:
	if victory_panel != null:
		victory_panel.queue_free()

	victory_panel = CanvasLayer.new()
	victory_panel.layer = 20
	add_child(victory_panel)

	# Dim background
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	victory_panel.add_child(dim)

	# Center anchor
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER)
	victory_panel.add_child(anchor)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 0)
	panel.position = Vector2(-250, -150)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.06, 0.95)
	style.border_color = Color(0.5, 0.45, 0.3, 0.8) if is_victory else Color(0.6, 0.2, 0.2, 0.8)
	style.border_width_top = 2
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.content_margin_left = 24.0
	style.content_margin_right = 24.0
	style.content_margin_top = 20.0
	style.content_margin_bottom = 20.0
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	panel.add_theme_stylebox_override("panel", style)
	anchor.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	# Header
	var header := Label.new()
	header.text = "VICTORY" if is_victory else "DEFEAT"
	header.add_theme_font_size_override("font_size", 36)
	header.add_theme_color_override("font_color",
		Color(0.9, 0.85, 0.5) if is_victory else Color(0.9, 0.3, 0.3))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)

	# Description
	var desc := Label.new()
	desc.text = description
	desc.add_theme_font_size_override("font_size", 18)
	desc.add_theme_color_override("font_color", Color(0.8, 0.78, 0.7))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	# Bonus objectives
	if not bonuses.is_empty():
		var bonus_header := Label.new()
		bonus_header.text = "Bonus Objectives Achieved:"
		bonus_header.add_theme_font_size_override("font_size", 16)
		bonus_header.add_theme_color_override("font_color", Color(0.7, 0.68, 0.55))
		vbox.add_child(bonus_header)

		for b in bonuses:
			var bl := Label.new()
			bl.text = "  - %s" % b
			bl.add_theme_font_size_override("font_size", 15)
			bl.add_theme_color_override("font_color", Color(0.75, 0.8, 0.55))
			vbox.add_child(bl)

		var points_label := Label.new()
		points_label.text = "Total bonus: %d points" % bonus_points
		points_label.add_theme_font_size_override("font_size", 16)
		points_label.add_theme_color_override("font_color", Color(0.85, 0.82, 0.5))
		vbox.add_child(points_label)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	# Return to menu button
	var btn := Button.new()
	btn.text = "Return to Menu"
	btn.custom_minimum_size = Vector2(200, 40)
	btn.add_theme_font_size_override("font_size", 18)
	btn.pressed.connect(_on_return_to_menu)
	vbox.add_child(btn)


func _on_return_to_menu() -> void:
	# Signal up to game_manager via input event
	var event := InputEventKey.new()
	event.keycode = KEY_F10
	event.pressed = true
	Input.parse_input_event(event)


func _update_enemy_ai() -> void:
	## Very basic enemy AI: move unordered enemy units toward row 0 (north).
	if scenario_loader == null:
		return

	# Don't advance until the designated time
	if scenario_loader.enemy_advance_hour >= 0:
		var advance_time: float = float(scenario_loader.enemy_advance_hour) * 60.0 + float(scenario_loader.enemy_advance_minute)
		if game_clock.game_time_minutes < advance_time:
			return

	for unit in units:
		if unit.get("side", "player") != "enemy":
			continue
		if unit.get("unit_status", "") in ["DESTROYED", "ROUTING"]:
			continue

		var uname: String = unit.get("name", "")
		var existing_order: Order = order_manager.get_order(uname)
		if existing_order != null and existing_order.status != Order.Status.COMPLETE:
			continue

		var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
		var is_hq: bool = utype.get("is_hq", false)

		# Pick a target hex: advance north (toward row 0)
		var cur_col: int = int(unit.get("col", 0))
		var cur_row: int = int(unit.get("row", 0))
		# Move ~8 hexes north, with slight variation to avoid stacking
		var target_row: int = maxi(0, cur_row - 8)
		var col_offset: int = (hash(uname) % 5) - 2  # -2 to +2 spread
		var target_col: int = clampi(cur_col + col_offset, 0, map_cols - 1)
		var target := Vector2i(target_col, target_row)

		# HQ units use hold fire and stay further back
		var ai_posture := Order.Posture.NORMAL
		var ai_roe := Order.ROE.FIRE_AT_WILL
		var ai_pursuit := Order.Pursuit.HOLD
		if is_hq:
			ai_roe = Order.ROE.HOLD_FIRE
			target_row = maxi(0, cur_row - 4)
			target = Vector2i(cur_col, target_row)

		var c2_ctx := _build_c2_context(unit)
		order_manager.issue_order(
			unit, utype, Order.Type.MOVE, target,
			game_clock.game_time_minutes, ai_posture, ai_roe, ai_pursuit, c2_ctx)


func _load_display_config() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/map.yaml")
	hex_size = cfg.get_float("map.hex_size", 40.0)
	hex_width = hex_size * 2.0
	hex_height = sqrt(3.0) * hex_size


func _load_map() -> void:
	if map_file == "":
		return

	var cfg := Config.new()
	cfg.load_file(map_file)
	map_cols = cfg.get_int("cols", 80)
	map_rows = cfg.get_int("rows", 60)

	# Parse terrain rows
	var terrain_rows = cfg.get_value("terrain", [])
	terrain_grid.clear()
	for row_str in terrain_rows:
		var row_data: Array[String] = []
		for c in str(row_str):
			row_data.append(c)
		terrain_grid.append(row_data)

	# Parse elevation rows
	var elev_rows = cfg.get_value("elevation", [])
	elevation_grid.clear()
	for row_str in elev_rows:
		var row_data: Array[int] = []
		var parts := str(row_str).split(" ")
		for p in parts:
			row_data.append(int(p))
		elevation_grid.append(row_data)

	# Map-specific sunrise/sunset override
	var map_sunrise: int = cfg.get_int("sunrise_hour", -1)
	var map_sunset: int = cfg.get_int("sunset_hour", -1)
	if map_sunrise >= 0:
		sunrise_hour = map_sunrise
	if map_sunset >= 0:
		sunset_hour = map_sunset


func _setup_info_label() -> void:
	# Info label is now created in _setup_display_bar
	pass


func _setup_unit_panel() -> void:
	unit_panel = UnitPanel.new()
	add_child(unit_panel)
	unit_panel.order_cleared.connect(_on_order_cleared)
	unit_panel.posture_changed.connect(_on_posture_changed)
	unit_panel.roe_changed.connect(_on_roe_changed)
	unit_panel.pursuit_changed.connect(_on_pursuit_changed)
	unit_panel.stack_unit_selected.connect(_on_stack_unit_selected)


func _setup_display_bar() -> void:
	display_bar = CanvasLayer.new()
	display_bar.layer = 10
	add_child(display_bar)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.05, 0.92)
	style.content_margin_left = 20.0
	style.content_margin_right = 20.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	panel.add_theme_stylebox_override("panel", style)

	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	anchor.offset_top = -36
	anchor.offset_bottom = 0
	display_bar.add_child(anchor)
	anchor.add_child(panel)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	panel.add_child(hbox)

	var cb_los := CheckBox.new()
	cb_los.text = "Line of Sight"
	cb_los.button_pressed = true
	cb_los.add_theme_font_size_override("font_size", 13)
	cb_los.add_theme_color_override("font_color", Color(0.78, 0.8, 0.72))
	cb_los.toggled.connect(func(pressed: bool) -> void: show_los = pressed; queue_redraw())
	hbox.add_child(cb_los)

	var cb_comms := CheckBox.new()
	cb_comms.text = "Comms Range"
	cb_comms.button_pressed = true
	cb_comms.add_theme_font_size_override("font_size", 13)
	cb_comms.add_theme_color_override("font_color", Color(0.78, 0.8, 0.72))
	cb_comms.toggled.connect(func(pressed: bool) -> void: show_comms = pressed; queue_redraw())
	hbox.add_child(cb_comms)

	var cb_weapons := CheckBox.new()
	cb_weapons.text = "Weapon Ranges"
	cb_weapons.button_pressed = true
	cb_weapons.add_theme_font_size_override("font_size", 13)
	cb_weapons.add_theme_color_override("font_color", Color(0.78, 0.8, 0.72))
	cb_weapons.toggled.connect(func(pressed: bool) -> void: show_weapon_ranges = pressed; queue_redraw())
	hbox.add_child(cb_weapons)

	var cb_units := CheckBox.new()
	cb_units.text = "Units"
	cb_units.button_pressed = true
	cb_units.add_theme_font_size_override("font_size", 13)
	cb_units.add_theme_color_override("font_color", Color(0.78, 0.8, 0.72))
	cb_units.toggled.connect(func(pressed: bool) -> void: show_units = pressed; queue_redraw())
	hbox.add_child(cb_units)

	var cb_elev := CheckBox.new()
	cb_elev.text = "Elevation"
	cb_elev.button_pressed = false
	cb_elev.add_theme_font_size_override("font_size", 13)
	cb_elev.add_theme_color_override("font_color", Color(0.78, 0.8, 0.72))
	cb_elev.toggled.connect(func(pressed: bool) -> void: show_elevation = pressed; queue_redraw())
	hbox.add_child(cb_elev)

	var cb_move := CheckBox.new()
	cb_move.text = "Movement Speed"
	cb_move.button_pressed = false
	cb_move.add_theme_font_size_override("font_size", 13)
	cb_move.add_theme_color_override("font_color", Color(0.78, 0.8, 0.72))
	cb_move.toggled.connect(func(pressed: bool) -> void: show_move_cost = pressed; queue_redraw())
	hbox.add_child(cb_move)

	# Spacer to push info label to the right
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Hotkeys info label (right side of bar)
	info_label = Label.new()
	info_label.add_theme_font_size_override("font_size", 12)
	info_label.add_theme_color_override("font_color", Color(0.6, 0.62, 0.55))
	hbox.add_child(info_label)

	# Separator before carousel
	var carousel_sep := VSeparator.new()
	carousel_sep.add_theme_constant_override("separation", 8)
	hbox.add_child(carousel_sep)

	# Unit carousel: < Name >
	carousel_left_btn = Button.new()
	carousel_left_btn.text = "<"
	carousel_left_btn.custom_minimum_size = Vector2(28, 0)
	carousel_left_btn.add_theme_font_size_override("font_size", 14)
	var cb_style := StyleBoxFlat.new()
	cb_style.bg_color = Color(0.15, 0.15, 0.15, 0.0)
	carousel_left_btn.add_theme_stylebox_override("normal", cb_style)
	carousel_left_btn.add_theme_color_override("font_color", Color(0.7, 0.72, 0.65))
	carousel_left_btn.pressed.connect(_carousel_prev)
	hbox.add_child(carousel_left_btn)

	carousel_label = Label.new()
	carousel_label.custom_minimum_size = Vector2(160, 0)
	carousel_label.add_theme_font_size_override("font_size", 13)
	carousel_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.8))
	carousel_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	carousel_label.mouse_filter = Control.MOUSE_FILTER_STOP
	carousel_label.gui_input.connect(_on_carousel_label_input)
	hbox.add_child(carousel_label)

	carousel_right_btn = Button.new()
	carousel_right_btn.text = ">"
	carousel_right_btn.custom_minimum_size = Vector2(28, 0)
	carousel_right_btn.add_theme_font_size_override("font_size", 14)
	carousel_right_btn.add_theme_stylebox_override("normal", cb_style.duplicate())
	carousel_right_btn.add_theme_color_override("font_color", Color(0.7, 0.72, 0.65))
	carousel_right_btn.pressed.connect(_carousel_next)
	hbox.add_child(carousel_right_btn)

	# Context menu for right-clicking units
	context_menu = PopupMenu.new()
	context_menu.add_item("Move (Cmd+L Click)", 0)
	context_menu.add_item("Attack (Cmd+R Click)", 1)
	context_menu.add_item("Patrol", 2)
	context_menu.add_item("Ambush", 3)
	context_menu.id_pressed.connect(_on_context_menu_selected)
	add_child(context_menu)


func _show_unit_context_menu(unit: Dictionary, screen_pos: Vector2) -> void:
	# Select the unit first
	var pos := Vector2i(unit["col"], unit["row"])
	selected_hex = pos
	selected_unit = unit
	_calculate_los(unit)
	_update_info_label()
	queue_redraw()

	context_menu_unit = unit
	context_menu.position = Vector2i(int(screen_pos.x), int(screen_pos.y))
	context_menu.popup()


func _on_context_menu_selected(id: int) -> void:
	if context_menu_unit.is_empty():
		return
	selected_unit = context_menu_unit
	match id:
		0:  # Move
			current_order_mode = Order.Type.MOVE
		1:  # Attack
			current_order_mode = Order.Type.ATTACK
		2:  # Patrol
			current_order_mode = Order.Type.PATROL
		3:  # Ambush
			current_order_mode = Order.Type.AMBUSH
	_update_info_label()
	context_menu_unit = {}


func _load_posture_configs() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/game.yaml")
	var postures = cfg.get_value("postures", {})
	for key in postures:
		var p: Dictionary = postures[key]
		posture_configs[key] = {
			"speed_modifier": float(p.get("speed_modifier", 1.0)),
			"detection_modifier": float(p.get("detection_modifier", 1.0)),
			"prep_modifier": float(p.get("prep_modifier", 1.0)),
			"road_preference": float(p.get("road_preference", 1.0)),
			"cover_preference": float(p.get("cover_preference", 0.5)),
		}


func _setup_game_flow() -> void:
	_load_posture_configs()
	game_clock = GameClock.new()
	add_child(game_clock)

	order_manager = OrderManager.new()
	add_child(order_manager)

	combat = Combat.new()

	combat_resolver = CombatResolver.new(hex_grid, units, unit_types,
		terrain_grid, elevation_grid, terrain_types,
		combat, order_manager, game_clock)
	combat_resolver.night_accuracy_modifier = night_accuracy_modifier
	combat_resolver.night_range_modifier = night_range_modifier
	combat_resolver.night_spotting_modifier = night_spotting_modifier
	combat_resolver.sunrise_hour = sunrise_hour
	combat_resolver.sunset_hour = sunset_hour
	combat_resolver.hq_los_accuracy_buff = hq_los_accuracy_buff
	combat_resolver.hq_los_suppression_resistance = hq_los_suppression_resistance
	combat_resolver.hq_los_morale_buff = hq_los_morale_buff
	combat_resolver.destruction_marker_duration = destruction_marker_duration
	combat_resolver.destruction_direct_hq_shock = destruction_direct_hq_shock
	combat_resolver.destruction_parent_hq_shock = destruction_parent_hq_shock
	combat_resolver.destruction_los_witness_shock = destruction_los_witness_shock
	combat_resolver.MORALE_BREAK_THRESHOLD = MORALE_BREAK_THRESHOLD
	combat_resolver.MORALE_ROUT_THRESHOLD = MORALE_ROUT_THRESHOLD
	combat_resolver.ROE_RATE_FIRE_AT_WILL = ROE_RATE_FIRE_AT_WILL
	combat_resolver.ROE_RATE_RETURN_FIRE = ROE_RATE_RETURN_FIRE
	combat_resolver.ROE_RATE_HALT_AND_ENGAGE = ROE_RATE_HALT_AND_ENGAGE
	combat_resolver.posture_configs = posture_configs
	combat_resolver.fire_effects = fire_effects
	combat_resolver.death_markers = death_markers
	combat_resolver.map_cols = map_cols
	combat_resolver.map_rows = map_rows

	movement = Movement.new(hex_grid, units, unit_types,
		terrain_grid, terrain_types, posture_configs, order_manager, game_clock)
	movement.combat = combat
	movement.death_markers = death_markers
	movement.unit_moved.connect(_on_unit_moved)

	hq_comms = HQComms.new(hex_grid, units, unit_types,
		elevation_grid, combat, order_manager, game_clock)
	hq_comms.hq_switching_cost = hq_switching_cost
	hq_comms.hq_comms_order_buff = hq_comms_order_buff
	hq_comms.hq_los_order_buff = hq_los_order_buff
	hq_comms.hq_los_morale_buff = hq_los_morale_buff
	hq_comms.hq_los_accuracy_buff = hq_los_accuracy_buff
	hq_comms.hq_los_suppression_resistance = hq_los_suppression_resistance
	hq_comms.hq_auto_switch_minutes = hq_auto_switch_minutes
	hq_comms.sunrise_hour = sunrise_hour
	hq_comms.sunset_hour = sunset_hour
	hq_comms.get_effective_spotting_range = combat_resolver.get_effective_spotting_range

	game_clock.time_advanced.connect(_on_time_advanced)

	game_flow_panel = GameFlowPanel.new()
	add_child(game_flow_panel)
	game_flow_panel.set_clock(game_clock)
	game_flow_panel.sunrise = sunrise_hour
	game_flow_panel.sunset = sunset_hour
	game_flow_panel.toggle_pause.connect(_toggle_pause)



func _build_carousel_order() -> void:
	carousel_order.clear()
	var player_hq1: Array = []  # battalion HQs
	var player_hq2: Array = []  # company HQs
	var player_by_hq: Dictionary = {}  # hq_name -> Array of units sorted by distance
	var player_no_hq: Array = []
	var dead_visible: Array = []
	var enemy_visible: Array = []

	for unit in units:
		var side: String = unit.get("side", "player")
		var status: String = unit.get("unit_status", "")

		if side == "enemy":
			var uname: String = unit.get("name", "")
			if uname in spotted_enemies and status != "DESTROYED":
				enemy_visible.append(unit)
			continue

		if status == "DESTROYED":
			var pos := Vector2i(unit["col"], unit["row"])
			if pos in death_markers:
				dead_visible.append(unit)
			continue

		var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
		if utype.get("is_hq", false):
			if int(utype.get("hq_level", 0)) == 1:
				player_hq1.append(unit)
			else:
				player_hq2.append(unit)
		else:
			var hq_name: String = unit.get("assigned_hq", "")
			if hq_name != "":
				if hq_name not in player_by_hq:
					player_by_hq[hq_name] = []
				player_by_hq[hq_name].append(unit)
			else:
				player_no_hq.append(unit)

	# Build order: BHQs, then for each SHQ: the SHQ followed by its units
	for hq in player_hq1:
		carousel_order.append(hq)
	for hq in player_hq2:
		carousel_order.append(hq)
		var hq_name: String = hq.get("name", "")
		if hq_name in player_by_hq:
			# Sort by distance from HQ
			var sub_units: Array = player_by_hq[hq_name]
			sub_units.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var da: int = hex_grid.hex_distance(Vector2i(a["col"], a["row"]), Vector2i(hq["col"], hq["row"]))
				var db: int = hex_grid.hex_distance(Vector2i(b["col"], b["row"]), Vector2i(hq["col"], hq["row"]))
				return da < db)
			for u in sub_units:
				carousel_order.append(u)
	for u in player_no_hq:
		carousel_order.append(u)
	for u in dead_visible:
		carousel_order.append(u)
	for u in enemy_visible:
		carousel_order.append(u)


func _update_carousel() -> void:
	if carousel_order.is_empty():
		carousel_label.text = "No units"
		return

	# Sync index to selected unit
	if not selected_unit.is_empty():
		var sel_name: String = selected_unit.get("name", "")
		for i in range(carousel_order.size()):
			if carousel_order[i].get("name", "") == sel_name:
				carousel_index = i
				break

	carousel_index = clampi(carousel_index, 0, carousel_order.size() - 1)
	var unit: Dictionary = carousel_order[carousel_index]
	var uname: String = unit.get("name", "?")
	var status: String = unit.get("unit_status", "")
	var side: String = unit.get("side", "player")

	var display := uname
	if status == "DESTROYED":
		display += " [X]"
	elif status == "ROUTING":
		display += " [!]"
	elif status == "BROKEN":
		display += " [!]"

	carousel_label.text = display
	if side == "enemy":
		carousel_label.add_theme_color_override("font_color", Color(0.9, 0.35, 0.25))
	elif status == "DESTROYED":
		carousel_label.add_theme_color_override("font_color", Color(0.5, 0.45, 0.4))
	else:
		carousel_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.8))


func _carousel_prev() -> void:
	if carousel_order.is_empty():
		return
	carousel_index = (carousel_index - 1) % carousel_order.size()
	if carousel_index < 0:
		carousel_index = carousel_order.size() - 1
	_carousel_select_current()


func _carousel_next() -> void:
	if carousel_order.is_empty():
		return
	carousel_index = (carousel_index + 1) % carousel_order.size()
	_carousel_select_current()


func _carousel_select_current() -> void:
	if carousel_index >= 0 and carousel_index < carousel_order.size():
		var unit: Dictionary = carousel_order[carousel_index]
		_select_and_center_unit(unit)
		_update_carousel()


func _on_carousel_label_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_carousel_select_current()


func _on_stack_unit_selected(unit_name: String) -> void:
	for unit in units:
		if unit.get("name", "") == unit_name:
			selected_unit = unit
			_calculate_los(unit)
			_update_info_label()
			queue_redraw()
			break


func _on_unit_moved(unit_name: String) -> void:
	if not selected_unit.is_empty() and selected_unit.get("name", "") == unit_name:
		# Find the unit dict (it may have moved)
		for unit in units:
			if unit.get("name", "") == unit_name:
				selected_unit = unit
				_calculate_los(unit)
				break


func _set_game_speed(speed: int) -> void:
	current_speed = clampi(speed, 1, 4)
	game_clock.seconds_per_game_minute = SPEED_VALUES[current_speed]
	game_flow_panel.set_speed(current_speed)


func _toggle_pause() -> void:
	game_clock.paused = not game_clock.paused
	game_flow_panel.set_paused(game_clock.paused)


func _select_and_center_unit(unit: Dictionary) -> void:
	var pos := Vector2i(unit["col"], unit["row"])
	selected_hex = pos
	selected_unit = unit
	_calculate_los(unit)
	# Center camera on unit
	var viewport_size := get_viewport_rect().size
	var pixel_pos: Vector2 = hex_grid.hex_to_pixel(pos.x, pos.y)
	camera_offset = pixel_pos * zoom_level - viewport_size * 0.5
	_clamp_camera()
	_update_info_label()
	queue_redraw()


func _on_posture_changed(unit_name: String, posture: Order.Posture) -> void:
	var order := order_manager.get_order(unit_name)
	if order != null and order.status != Order.Status.EXECUTING:
		order.posture = posture
		current_posture = posture
		_update_info_label()
		queue_redraw()


func _on_roe_changed(unit_name: String, roe: Order.ROE) -> void:
	var order := order_manager.get_order(unit_name)
	if order != null and order.status != Order.Status.EXECUTING:
		order.roe = roe
		current_roe = roe
		_update_info_label()
		queue_redraw()


func _on_pursuit_changed(unit_name: String, pursuit: Order.Pursuit) -> void:
	var order := order_manager.get_order(unit_name)
	if order != null and order.status != Order.Status.EXECUTING:
		order.pursuit = pursuit
		current_pursuit = pursuit
		_update_info_label()
		queue_redraw()


func _on_order_cleared(unit_name: String) -> void:
	order_manager.cancel_order(unit_name)
	_update_info_label()
	queue_redraw()


func _init_fog_of_war() -> void:
	## Pre-reveal hexes based on fog_of_war_mode
	match fog_of_war_mode:
		"full_knowledge":
			# Local knowledge - know every hill, every grove, every elevation
			for row in range(map_rows):
				for col in range(map_cols):
					var pos := Vector2i(col, row)
					revealed_hexes[pos] = true
					elevation_revealed[pos] = true
		"satellite":
			# Satellite: all terrain types visible everywhere (can see forests vs fields)
			# But elevation only accurate near mapped infrastructure
			for row in range(map_rows):
				for col in range(map_cols):
					revealed_hexes[Vector2i(col, row)] = true
			# Elevation only near roads/towns/cities/rivers
			for row in range(map_rows):
				for col in range(map_cols):
					var code: String = terrain_grid[row][col]
					if code == "S" or code == "T" or code == "C" or code == "R":
						for dc in range(-satellite_range, satellite_range + 1):
							for dr in range(-satellite_range, satellite_range + 1):
								var c: int = col + dc
								var r: int = row + dr
								if c >= 0 and c < map_cols and r >= 0 and r < map_rows:
									if hex_grid.hex_distance(Vector2i(col, row), Vector2i(c, r)) <= satellite_range:
										elevation_revealed[Vector2i(c, r)] = true
		"approximate":
			# Infrastructure visible, rest hidden. No elevation until scouted.
			pass
		"total":
			# Nothing visible until scouted
			pass


func _update_fog_of_war() -> void:
	# 1. Reveal hexes within player units' extended spotting range
	for unit in units:
		if unit.get("side", "player") != "player":
			continue
		var unit_pos := Vector2i(unit["col"], unit["row"])
		var reveal_range: int = combat_resolver.get_effective_spotting_range(unit) + 3
		for dc in range(-reveal_range, reveal_range + 1):
			for dr in range(-reveal_range, reveal_range + 1):
				var c: int = unit_pos.x + dc
				var r: int = unit_pos.y + dr
				if c < 0 or c >= map_cols or r < 0 or r >= map_rows:
					continue
				var hex_coord := Vector2i(c, r)
				if hex_grid.hex_distance(unit_pos, hex_coord) <= reveal_range:
					revealed_hexes[hex_coord] = true
					elevation_revealed[hex_coord] = true  # boots on ground = know the terrain

	# 2. Find currently spotted enemy units
	var new_spotted: Dictionary = {}
	for unit in units:
		if unit.get("side", "player") != "player":
			continue
		var targets: Array = combat_resolver.find_targets_in_range(unit)
		for target in targets:
			var tname: String = target.get("name", "")
			var tpos := Vector2i(target["col"], target["row"])
			new_spotted[tname] = tpos

	# 2b. Town support spotting - friendly towns spot enemies in their radius
	if scenario_loader != null:
		for ts in scenario_loader.town_support:
			var ts_faction: String = str(ts.get("faction", ""))
			if ts_faction != "player":
				continue
			var ts_hex_arr = ts.get("hex", [])
			if not (ts_hex_arr is Array) or ts_hex_arr.size() < 2:
				continue
			var ts_pos := Vector2i(int(ts_hex_arr[0]), int(ts_hex_arr[1]))
			var ts_range: int = int(ts.get("spot_range", 8))
			var ts_elev: int = elevation_grid[ts_pos.y][ts_pos.x]
			for enemy in units:
				if enemy.get("side", "player") == "player":
					continue
				if enemy.get("unit_status", "") == "DESTROYED":
					continue
				var e_pos := Vector2i(enemy["col"], enemy["row"])
				if hex_grid.hex_distance(ts_pos, e_pos) <= ts_range:
					if hex_grid.has_los(ts_pos, ts_elev, e_pos):
						var ename: String = enemy.get("name", "")
						new_spotted[ename] = e_pos

	# 3. Enemies that were spotted last tick but aren't now -> last_seen
	for uname in spotted_enemies:
		if uname not in new_spotted:
			var old_pos: Vector2i = spotted_enemies[uname]
			last_seen_enemies[old_pos] = game_clock.game_time_minutes

	spotted_enemies = new_spotted

	# 4. Clean up expired last-seen markers
	var to_remove: Array = []
	for pos in last_seen_enemies:
		var age: float = game_clock.game_time_minutes - float(last_seen_enemies[pos])
		if age > LAST_SEEN_DURATION:
			to_remove.append(pos)
	for pos in to_remove:
		last_seen_enemies.erase(pos)

	# 5. Clear last-seen markers for positions where an enemy is currently spotted
	for uname in spotted_enemies:
		var pos: Vector2i = spotted_enemies[uname]
		if pos in last_seen_enemies:
			last_seen_enemies.erase(pos)


func _apply_command_shock() -> void:
	## Propagate subordinate suppression to HQ units.
	## When units under an HQ take fire, the HQ feels it too.
	for unit in units:
		var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
		if not utype.get("is_hq", false):
			continue
		if unit.get("unit_status", "") == "DESTROYED":
			continue

		var hq_name: String = unit.get("name", "")
		var side: String = unit.get("side", "player")

		# Get command shock ratio from faction C2 config
		var c2: Dictionary = order_manager.get_c2(side)
		var shock_ratio: float = float(c2.get("command_shock_ratio", 0.1))
		if shock_ratio <= 0.0:
			continue

		# Sum suppression of all units assigned to this HQ
		var total_sub_suppression: float = 0.0
		for sub in units:
			if sub.get("assigned_hq", "") != hq_name:
				continue
			if sub.get("unit_status", "") == "DESTROYED":
				continue
			var sub_supp: float = combat.get_suppression(sub.get("name", ""))
			if sub_supp > 0:
				total_sub_suppression += sub_supp

		if total_sub_suppression > 0:
			var shock_amount: float = total_sub_suppression * shock_ratio
			combat.apply_suppression(hq_name, shock_amount)


func _on_time_advanced(minutes: float) -> void:
	hq_comms.update_hq_comms(minutes)
	order_manager.update_orders(game_clock.game_time_minutes)
	movement.move_units(minutes)
	# Resolve combat for all units and decay suppression
	for unit in units:
		combat_resolver.resolve_unit_combat(unit, minutes)
	combat.decay_suppression(minutes)
	# Command shock: subordinate suppression propagates to HQ
	_apply_command_shock()
	# Update morale and recover for units not under fire
	for unit in units:
		combat_resolver.check_morale(unit)
		combat_resolver.recover_morale(unit, minutes)
	# Check pursuit triggers
	combat_resolver.check_pursuit()
	# Update fog of war
	_update_fog_of_war()
	# Scenario systems
	if scenario_loader != null and not scenario_ended:
		_check_reinforcements()
		_check_victory_conditions()
		# Enemy AI: update every ENEMY_AI_INTERVAL game minutes
		enemy_ai_accum += minutes
		if enemy_ai_accum >= ENEMY_AI_INTERVAL:
			enemy_ai_accum -= ENEMY_AI_INTERVAL
			_update_enemy_ai()
	# Keep selection tracking the selected unit
	if not selected_unit.is_empty():
		selected_hex = Vector2i(selected_unit["col"], selected_unit["row"])
		_update_info_label()
	# Throttle redraws - only every 10th tick during gameplay
	_redraw_counter += 1
	if _redraw_counter >= 10:
		_redraw_counter = 0
		queue_redraw()
		# Write game log infrequently too
		_log_counter += 1
		if _log_counter >= 6:  # every 60 ticks
			_log_counter = 0
			_write_game_log()


func _write_game_log() -> void:
	var file := FileAccess.open("user://game_state.log", FileAccess.WRITE)
	if file == null:
		return
	file.store_line("=== GAME STATE at %s ===" % game_clock.get_time_string())
	file.store_line("Status: %s" % ("PAUSED" if game_clock.paused else "RUNNING"))
	file.store_line("Night: %s" % str(_is_night()))
	file.store_line("")

	for unit in units:
		var uname: String = unit.get("name", "?")
		var utype_code: String = unit.get("type_code", "")
		var utype: Dictionary = unit_types.get(utype_code, {})
		var pos := Vector2i(unit["col"], unit["row"])
		var status: String = unit.get("unit_status", "")
		if status == "":
			status = "OK"
		var cur_morale: int = int(unit.get("current_morale", 0))
		var morale_dmg: int = int(unit.get("morale_damage", 0))
		var cur_crew: int = int(unit.get("current_crew", 0))
		var max_crew: int = int(utype.get("crew", 0))
		var vdmg: float = float(unit.get("vehicle_damage", 0.0))
		var mobdmg: float = float(unit.get("mobility_damage", 0.0))
		var supp: float = combat.get_suppression(uname)
		var in_comms: bool = unit.get("in_comms", false)
		var in_los: bool = unit.get("in_hq_los", false)
		var assigned_hq: String = unit.get("assigned_hq", "")

		file.store_line("[%s] %s (%s)  side=%s  pos=(%d,%d)" % [
			utype_code, uname, status, unit.get("side", "?"), pos.x, pos.y])
		file.store_line("  Morale: %d (base %d, permanent dmg: %d)  Crew: %d/%d" % [
			cur_morale, int(utype.get("morale", 50)), morale_dmg, cur_crew, max_crew])
		file.store_line("  Vehicle: %.0f%% dmg  Mobility: %.0f%% dmg  Suppression: %.0f%%" % [
			vdmg * 100, mobdmg * 100, supp])
		file.store_line("  HQ: %s  Comms: %s  LOS: %s" % [assigned_hq, str(in_comms), str(in_los)])

		var ammo_arr: Array = unit.get("current_ammo", [])
		var weapons: Array = utype.get("weapons", [])
		if weapons is Array:
			for wi in range(weapons.size()):
				var w: Dictionary = weapons[wi]
				var cur_ammo: int = int(ammo_arr[wi]) if wi < ammo_arr.size() else 0
				var max_ammo: int = int(w.get("ammo", 0))
				file.store_line("  Weapon: %s  Ammo: %d/%d" % [w.get("name", "?"), cur_ammo, max_ammo])

		var order: Order = order_manager.get_order(uname)
		if order != null:
			file.store_line("  Order: %s  Status: %s  Posture: %s  ROE: %s  Pursuit: %s" % [
				Order.type_to_string(order.type),
				order.status_string(),
				Order.posture_to_string(order.posture),
				Order.roe_to_string(order.roe),
				Order.pursuit_to_string(order.pursuit)])
			file.store_line("  Waypoints: %d (current: %d)" % [order.waypoint_count(), order.current_waypoint_index])
		file.store_line("")

	# Combat log (last 20 entries)
	file.store_line("=== COMBAT LOG (recent) ===")
	var log_start: int = maxi(0, combat.combat_log.size() - 20)
	for i in range(log_start, combat.combat_log.size()):
		file.store_line(combat.combat_log[i])

	file.close()


func _process(delta: float) -> void:

	# Decay fire effects (real time, not game time)
	var effects_to_remove: Array[int] = []
	for i in range(fire_effects.size()):
		fire_effects[i]["time_remaining"] = float(fire_effects[i]["time_remaining"]) - delta
		if float(fire_effects[i]["time_remaining"]) <= 0:
			effects_to_remove.append(i)
	for i in range(effects_to_remove.size() - 1, -1, -1):
		fire_effects.remove_at(effects_to_remove[i])
	if not fire_effects.is_empty():
		queue_redraw()

	# Update info label
	_update_info_label()


func _draw() -> void:
	# Background
	var viewport_size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, viewport_size), Color(0.15, 0.18, 0.12))

	if terrain_grid.is_empty():
		return

	# Calculate visible hex range
	var margin := 2
	var top_left := camera_offset / zoom_level
	var bottom_right := top_left + viewport_size / zoom_level

	var min_col := maxi(0, int(top_left.x / (hex_width * 0.75)) - margin)
	var max_col := mini(map_cols - 1, int(bottom_right.x / (hex_width * 0.75)) + margin)
	var min_row := maxi(0, int(top_left.y / hex_height) - margin)
	var max_row := mini(map_rows - 1, int(bottom_right.y / hex_height) + margin)

	var scaled_size := hex_size * zoom_level

	for col in range(min_col, max_col + 1):
		for row in range(min_row, max_row + 1):
			var center : Vector2 = (hex_grid.hex_to_pixel(col, row) - camera_offset / zoom_level) * zoom_level
			var code: String = terrain_grid[row][col]
			var elev: int = elevation_grid[row][col] if row < elevation_grid.size() and col < elevation_grid[row].size() else 5

			# Get base color from terrain type
			var base_color := Color(0.8, 0.8, 0.8)
			if code in terrain_types:
				base_color = terrain_types[code]["color"]

			# Apply elevation shading (only if elevation is known)
			var hex_coord := Vector2i(col, row)
			var shade := 0.0
			if hex_coord in elevation_revealed:
				shade = lerpf(elev_min_shade, elev_max_shade, elev / 9.0)
			var color := Color(
				clampf(base_color.r + shade, 0, 1),
				clampf(base_color.g + shade, 0, 1),
				clampf(base_color.b + shade, 0, 1)
			)

			# Fog of war: check if hex is revealed
			var always_known := false
			if fog_of_war_mode != "total":
				always_known = code == "S" or code == "T" or code == "C" or code == "R"
			var is_revealed := always_known or hex_coord in revealed_hexes

			if is_revealed:
				_draw_hex_filled(center, scaled_size, color)
				_draw_hex_detail(center, scaled_size, code)
			else:
				_draw_hex_filled(center, scaled_size, Color(0.18, 0.2, 0.17))

			# Hex overlay labels (elevation, movement) - only on revealed hexes
			if scaled_size > 10 and is_revealed:
				var font := ThemeDB.fallback_font
				var label_size := int(clampf(scaled_size * 0.22, 7, 14))
				if show_elevation and hex_coord in elevation_revealed:
					var elev_text := str(elev)
					var text_sz := font.get_string_size(elev_text, HORIZONTAL_ALIGNMENT_CENTER, -1, label_size)
					var elev_pos := center + Vector2(-text_sz.x * 0.5, -scaled_size * 0.35)
					draw_string(font, elev_pos + Vector2(1, 1), elev_text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, Color(0, 0, 0, 0.5))
					draw_string(font, elev_pos, elev_text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, Color(1, 1, 1, 0.6))
				if show_move_cost:
					var spd_mod: float = 1.0
					if code in terrain_types:
						spd_mod = float(terrain_types[code].get("speed_modifier", 1.0))
					var spd_text := "%d%%" % int(spd_mod * 100)
					var text_sz := font.get_string_size(spd_text, HORIZONTAL_ALIGNMENT_CENTER, -1, label_size)
					var spd_pos := center + Vector2(-text_sz.x * 0.5, scaled_size * 0.45)
					draw_string(font, spd_pos + Vector2(1, 1), spd_text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, Color(0, 0, 0, 0.5))
					draw_string(font, spd_pos, spd_text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, Color(1, 1, 1, 0.6))

			# Outline
			var outline_color := Color(0.3, 0.35, 0.25, 0.4)
			if Vector2i(col, row) == selected_hex:
				outline_color = COLOR_SELECT_OUTLINE
			elif Vector2i(col, row) == hovered_hex:
				outline_color = COLOR_HOVER_OUTLINE

			_draw_hex_outline(center, scaled_size, outline_color)

	# Draw map labels (town/city names)
	if scenario_loader != null and scaled_size > 12:
		var label_font := ThemeDB.fallback_font
		var label_font_size := int(clampf(scaled_size * 0.25, 8, 14))
		for ml in scenario_loader.map_labels:
			var ml_hex_arr = ml.get("hex", [])
			if not (ml_hex_arr is Array) or ml_hex_arr.size() < 2:
				continue
			var ml_col: int = int(ml_hex_arr[0])
			var ml_row: int = int(ml_hex_arr[1])
			if ml_col < min_col - 2 or ml_col > max_col + 2 or ml_row < min_row - 2 or ml_row > max_row + 2:
				continue
			var ml_name: String = str(ml.get("name", ""))
			if ml_name == "":
				continue
			var ml_screen: Vector2 = (hex_grid.hex_to_pixel(ml_col, ml_row) - camera_offset / zoom_level) * zoom_level
			var text_size := label_font.get_string_size(ml_name, HORIZONTAL_ALIGNMENT_CENTER, -1, label_font_size)
			var ml_pos := ml_screen + Vector2(-text_size.x * 0.5, scaled_size * 0.75)
			# Shadow
			draw_string(label_font, ml_pos + Vector2(1, 1), ml_name, HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size, Color(0, 0, 0, 0.7))
			draw_string(label_font, ml_pos, ml_name, HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size, Color(0.9, 0.85, 0.7, 0.8))

	# Draw terrain LOS preview (Cmd+Click on empty hex)
	if show_los and not terrain_los_preview.is_empty() and selected_unit.is_empty():
		for col in range(min_col, max_col + 1):
			for row in range(min_row, max_row + 1):
				var coord := Vector2i(col, row)
				var center : Vector2 = (hex_grid.hex_to_pixel(col, row) - camera_offset / zoom_level) * zoom_level
				if coord in terrain_los_preview:
					_draw_hex_filled(center, scaled_size * 0.92, Color(0.3, 0.7, 0.9, 0.15))
				elif hex_grid.hex_distance(terrain_los_origin, coord) <= TERRAIN_LOS_RANGE:
					_draw_hex_filled(center, scaled_size * 0.92, Color(0.9, 0.2, 0.1, 0.1))

	# Draw LOS overlay when a unit is selected
	if show_los and not selected_unit.is_empty() and not los_visible.is_empty():
		for col in range(min_col, max_col + 1):
			for row in range(min_row, max_row + 1):
				var coord := Vector2i(col, row)
				var center : Vector2 = (hex_grid.hex_to_pixel(col, row) - camera_offset / zoom_level) * zoom_level
				if coord in los_visible:
					# Visible: light green tint
					_draw_hex_filled(center, scaled_size * 0.92, Color(0.3, 0.9, 0.3, 0.12))
				else:
					# Check if within spotting range but not visible
					var unit_coord := Vector2i(selected_unit["col"], selected_unit["row"])
					if hex_grid.hex_distance(unit_coord, coord) <= combat_resolver.get_effective_spotting_range(selected_unit):
						# In range but blocked: dim red
						_draw_hex_filled(center, scaled_size * 0.92, Color(0.9, 0.2, 0.1, 0.15))

	# Draw weapon range rings when a unit is selected
	if (show_weapon_ranges or show_comms) and not selected_unit.is_empty():
		var utype_code: String = selected_unit["type_code"]
		if utype_code in unit_types:
			var utype: Dictionary = unit_types[utype_code]
			var weapons = utype.get("weapons", [])
			var unit_pos := Vector2i(selected_unit["col"], selected_unit["row"])
			var unit_screen : Vector2 = (hex_grid.hex_to_pixel(unit_pos.x, unit_pos.y) - camera_offset / zoom_level) * zoom_level

			# Assign colors per weapon
			var ring_colors := [
				Color(0.9, 0.4, 0.2, 0.4),  # orange
				Color(0.2, 0.6, 0.9, 0.4),  # blue
				Color(0.9, 0.9, 0.2, 0.4),  # yellow
				Color(0.9, 0.2, 0.6, 0.4),  # pink
			]

			# Check if unit is currently moving
			var unit_order: Order = order_manager.get_order(selected_unit.get("name", ""))
			var is_moving := unit_order != null and unit_order.status == Order.Status.EXECUTING

			for wi in range(weapons.size()):
				if not show_weapon_ranges:
					continue
				var w: Dictionary = weapons[wi]
				var range_static: float = float(w.get("range_km", 0))
				var range_moving: float = float(w.get("range_moving_km", range_static * 0.3))
				var supp_range: float = float(w.get("suppressive_range_km", range_static))
				var range_km: float = range_moving if is_moving else range_static
				var supp_km: float = range_moving if is_moving else supp_range
				var ring_color: Color = ring_colors[wi % ring_colors.size()]
				var line_w := maxf(1.5, scaled_size * 0.04)
				var segments := 48

				# Draw suppressive range ring (dashed, dimmer)
				if supp_km > range_km:
					var supp_radius := (supp_km / 0.5) * hex_height * zoom_level
					var supp_color := ring_color
					supp_color.a *= 0.4
					for i in range(segments):
						if i % 3 == 0:
							continue  # dashed
						var a0 := deg_to_rad(float(i) / segments * 360.0)
						var a1 := deg_to_rad(float(i + 1) / segments * 360.0)
						var p0 := unit_screen + Vector2(cos(a0), sin(a0)) * supp_radius
						var p1 := unit_screen + Vector2(cos(a1), sin(a1)) * supp_radius
						draw_line(p0, p1, supp_color, line_w * 0.7)

				# Draw effective range ring (solid)
				var range_hexes: float = range_km / 0.5
				var ring_radius := range_hexes * hex_height * zoom_level
				for i in range(segments):
					if is_moving and i % 3 == 0:
						continue
					var a0 := deg_to_rad(float(i) / segments * 360.0)
					var a1 := deg_to_rad(float(i + 1) / segments * 360.0)
					var p0 := unit_screen + Vector2(cos(a0), sin(a0)) * ring_radius
					var p1 := unit_screen + Vector2(cos(a1), sin(a1)) * ring_radius
					draw_line(p0, p1, ring_color, line_w)

				# Label
				if scaled_size > 10:
					var font := ThemeDB.fallback_font
					var wname: String = w.get("name", "?")
					var move_tag := " MOV" if is_moving else ""
					var label_text := "%s (%.1fkm%s)" % [wname, range_km, move_tag]
					var font_size := int(clampf(scaled_size * 0.18, 8, 13))
					var label_pos := unit_screen + Vector2(ring_radius + 4, -font_size * 0.5 - wi * (font_size + 4))
					draw_string(font, label_pos + Vector2(1, 1), label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.6))
					draw_string(font, label_pos, label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ring_color)

			# Draw comms range ring for HQ units
			var comms_data = utype.get("comms", {})
			if show_comms and not comms_data.is_empty():
				var comms_range_km: float = float(comms_data.get("range_km", 0))
				var comms_hexes: float = comms_range_km / 0.5
				var comms_radius := comms_hexes * hex_height * zoom_level
				var comms_color := Color(0.2, 0.8, 0.8, 0.3)  # cyan/teal
				var comms_line_w := maxf(3.5, scaled_size * 0.12)
				var comms_segments := 48
				# Draw dashed ring
				for i in range(comms_segments):
					if i % 2 == 0:
						var a0 := deg_to_rad(float(i) / comms_segments * 360.0)
						var a1 := deg_to_rad(float(i + 1) / comms_segments * 360.0)
						var p0 := unit_screen + Vector2(cos(a0), sin(a0)) * comms_radius
						var p1 := unit_screen + Vector2(cos(a1), sin(a1)) * comms_radius
						draw_line(p0, p1, comms_color, comms_line_w)
				# Label
				if scaled_size > 10:
					var comms_font := ThemeDB.fallback_font
					var comms_label := "%s (%.0fkm)" % [comms_data.get("name", "Radio"), comms_range_km]
					var comms_font_size := int(clampf(scaled_size * 0.18, 8, 13))
					var comms_label_pos := unit_screen + Vector2(comms_radius + 4, comms_font_size * 0.5 + weapons.size() * (comms_font_size + 4))
					draw_string(comms_font, comms_label_pos + Vector2(1, 1), comms_label, HORIZONTAL_ALIGNMENT_LEFT, -1, comms_font_size, Color(0, 0, 0, 0.6))
					draw_string(comms_font, comms_label_pos, comms_label, HORIZONTAL_ALIGNMENT_LEFT, -1, comms_font_size, comms_color)

	# Draw order waypoint lines and markers (player units only)
	for unit in units:
		if unit.get("side", "player") != "player":
			continue
		var uname: String = unit["name"]
		var order: Order = order_manager.get_order(uname)
		if order == null or order.status == Order.Status.COMPLETE or order.status == Order.Status.COUNTERMANDED:
			continue
		if order.waypoints.is_empty():
			continue

		var is_dashed := order.status != Order.Status.EXECUTING
		var line_w := maxf(2.0, scaled_size * 0.05)

		# Start from unit position
		var prev_screen : Vector2 = (hex_grid.hex_to_pixel(unit["col"], unit["row"]) - camera_offset / zoom_level) * zoom_level

		for wi in range(order.waypoints.size()):
			var wp: Dictionary = order.waypoints[wi]
			var wp_hex: Vector2i = wp["hex"]
			var wp_posture: Order.Posture = wp["posture"]
			var wp_screen : Vector2 = (hex_grid.hex_to_pixel(wp_hex.x, wp_hex.y) - camera_offset / zoom_level) * zoom_level

			# Color by waypoint posture
			var line_color := Color(0.7, 0.3, 0.9, 0.6)
			match wp_posture:
				Order.Posture.FAST:
					line_color = Color(0.85, 0.4, 0.95, 0.7)
				Order.Posture.CAUTIOUS:
					line_color = Color(0.5, 0.2, 0.75, 0.5)

			# Dim past waypoints
			if wi < order.current_waypoint_index:
				line_color.a *= 0.3

			# Draw line segment
			if is_dashed or wi < order.current_waypoint_index:
				var segments := 12
				for i in range(segments):
					if i % 2 == 0:
						var t0 := float(i) / segments
						var t1 := float(i + 1) / segments
						draw_line(prev_screen.lerp(wp_screen, t0), prev_screen.lerp(wp_screen, t1), line_color, line_w)
			else:
				draw_line(prev_screen, wp_screen, line_color, line_w)

			# Waypoint marker
			var marker_color := line_color
			marker_color.a = 0.8
			_draw_hex_outline(wp_screen, scaled_size * 0.85, marker_color)

			# Waypoint number and posture label
			if scaled_size > 12:
				var font := ThemeDB.fallback_font
				var wp_label := "%d: %s" % [wi + 1, Order.posture_to_string(wp_posture).to_upper()]
				var font_size := int(clampf(scaled_size * 0.2, 8, 14))
				var text_size := font.get_string_size(wp_label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
				var text_pos := wp_screen + Vector2(-text_size.x * 0.5, scaled_size * 0.9 + font_size)
				draw_string(font, text_pos, wp_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, marker_color)

			prev_screen = wp_screen

		# Draw attack target indicator
		if order.type == Order.Type.ATTACK and order.attack_target != Vector2i(-1, -1):
			var fp_screen := prev_screen  # last waypoint screen pos (firing position)
			var at_hex: Vector2i = order.attack_target
			var at_screen := (hex_grid.hex_to_pixel(at_hex.x, at_hex.y) - camera_offset / zoom_level) * zoom_level
			# Red dashed line from firing position to target
			var atk_color := Color(0.9, 0.2, 0.1, 0.6)
			var atk_segments := 8
			for i in range(atk_segments):
				if i % 2 == 0:
					var t0 := float(i) / atk_segments
					var t1 := float(i + 1) / atk_segments
					draw_line(fp_screen.lerp(at_screen, t0), fp_screen.lerp(at_screen, t1), atk_color, line_w)
			# Crosshair on target
			var ch_size := scaled_size * 0.3
			draw_line(at_screen + Vector2(-ch_size, 0), at_screen + Vector2(ch_size, 0), atk_color, line_w)
			draw_line(at_screen + Vector2(0, -ch_size), at_screen + Vector2(0, ch_size), atk_color, line_w)
			# Circle around crosshair
			var ch_r := ch_size * 1.2
			var ch_prev := at_screen + Vector2(ch_r, 0)
			for ci in range(1, 17):
				var a := deg_to_rad(float(ci) / 16.0 * 360.0)
				var ch_next := at_screen + Vector2(cos(a), sin(a)) * ch_r
				draw_line(ch_prev, ch_next, atk_color, line_w * 0.7)
				ch_prev = ch_next

	# Draw last-seen enemy markers (small red circle, not hex fill)
	for pos in last_seen_enemies:
		var age: float = game_clock.game_time_minutes - float(last_seen_enemies[pos])
		if age > LAST_SEEN_DURATION:
			continue
		var lse_alpha: float = clampf(1.0 - age / LAST_SEEN_DURATION, 0.0, 1.0) * 0.6
		var screen_pos : Vector2 = (hex_grid.hex_to_pixel(pos.x, pos.y) - camera_offset / zoom_level) * zoom_level
		var circle_r := scaled_size * 0.25
		var circle_color := Color(0.85, 0.15, 0.1, lse_alpha)
		var segments := 16
		var prev_pt := screen_pos + Vector2(circle_r, 0)
		for ci in range(1, segments + 1):
			var a := deg_to_rad(float(ci) / segments * 360.0)
			var next_pt := screen_pos + Vector2(cos(a), sin(a)) * circle_r
			draw_line(prev_pt, next_pt, circle_color, maxf(1.5, scaled_size * 0.04))
			prev_pt = next_pt

	# Draw death markers (skull-like X)
	for pos in death_markers:
		var age: float = game_clock.game_time_minutes - float(death_markers[pos])
		if age > destruction_marker_duration:
			continue
		var dm_alpha: float = clampf(1.0 - age / destruction_marker_duration, 0.3, 0.9)
		var dm_screen : Vector2 = (hex_grid.hex_to_pixel(pos.x, pos.y) - camera_offset / zoom_level) * zoom_level
		var dm_size := scaled_size * 0.3
		var dm_color := Color(0.7, 0.1, 0.05, dm_alpha)
		var dm_w := maxf(2.0, scaled_size * 0.06)
		# Draw X
		draw_line(dm_screen + Vector2(-dm_size, -dm_size), dm_screen + Vector2(dm_size, dm_size), dm_color, dm_w)
		draw_line(dm_screen + Vector2(dm_size, -dm_size), dm_screen + Vector2(-dm_size, dm_size), dm_color, dm_w)
		# Draw circle around X
		var dm_r := dm_size * 1.3
		var dm_prev := dm_screen + Vector2(dm_r, 0)
		for dmi in range(1, 17):
			var dm_a := deg_to_rad(float(dmi) / 16.0 * 360.0)
			var dm_next := dm_screen + Vector2(cos(dm_a), sin(dm_a)) * dm_r
			draw_line(dm_prev, dm_next, dm_color, dm_w * 0.7)
			dm_prev = dm_next

	# Draw units on top
	if show_units:
		# Count visible units per hex for stacking offset
		var hex_unit_index: Dictionary = {}  # Vector2i -> int (count so far)
		var hex_unit_total: Dictionary = {}  # Vector2i -> int (total)
		var drawable_units: Array = []
		var selected_draw: Dictionary = {}  # draw selected unit last (on top)

		for unit in units:
			if unit.get("unit_status", "") == "DESTROYED":
				continue
			var unit_side: String = unit.get("side", "player")
			if unit_side == "enemy":
				var uname: String = unit.get("name", "")
				if uname not in spotted_enemies:
					continue
			var pos := Vector2i(unit["col"], unit["row"])
			if not pos in hex_unit_total:
				hex_unit_total[pos] = 0
			hex_unit_total[pos] = int(hex_unit_total[pos]) + 1
			if not selected_unit.is_empty() and unit.get("name", "") == selected_unit.get("name", ""):
				selected_draw = unit
			else:
				drawable_units.append(unit)

		# Draw non-selected units first, selected on top
		if not selected_draw.is_empty():
			drawable_units.append(selected_draw)

		for unit in drawable_units:
			var uc: int = unit["col"]
			var ur: int = unit["row"]
			if uc >= min_col and uc <= max_col and ur >= min_row and ur <= max_row:
				var pos := Vector2i(uc, ur)
				var center : Vector2 = (hex_grid.hex_to_pixel(uc, ur) - camera_offset / zoom_level) * zoom_level
				# Stack offset
				var total: int = int(hex_unit_total.get(pos, 1))
				if total > 1:
					if not pos in hex_unit_index:
						hex_unit_index[pos] = 0
					var idx: int = int(hex_unit_index[pos])
					var offset_x: float = float(idx) * scaled_size * 0.15
					var offset_y: float = float(idx) * scaled_size * -0.1
					center += Vector2(offset_x, offset_y)
					hex_unit_index[pos] = idx + 1
				var type_code: String = unit["type_code"]
				var unit_side: String = unit.get("side", "player")
				if type_code in unit_types:
					_draw_unit_counter(center, scaled_size, unit_types[type_code], unit["name"], unit_side)

	# Draw fire effects - red lines from shooter to target, flash on hit
	for effect in fire_effects:
		var from_hex: Vector2i = effect["from"]
		var to_hex: Vector2i = effect["to"]
		var t_remaining: float = float(effect["time_remaining"])
		var is_hit: bool = effect["hit"]
		var alpha: float = clampf(t_remaining / FIRE_EFFECT_DURATION, 0.0, 1.0)

		var from_screen : Vector2 = (hex_grid.hex_to_pixel(from_hex.x, from_hex.y) - camera_offset / zoom_level) * zoom_level
		var to_screen : Vector2 = (hex_grid.hex_to_pixel(to_hex.x, to_hex.y) - camera_offset / zoom_level) * zoom_level

		# Fire line
		var line_color := Color(1.0, 0.3, 0.1, alpha * 0.7)
		draw_line(from_screen, to_screen, line_color, maxf(1.5, scaled_size * 0.03))

		# Flash on target hex if hit
		if is_hit:
			var flash_alpha := alpha * 0.4
			_draw_hex_filled(to_screen, scaled_size * 0.9, Color(1.0, 0.1, 0.0, flash_alpha))


func _draw_hex_filled(center: Vector2, size: float, color: Color) -> void:
	var points := PackedVector2Array()
	for i in range(6):
		var angle := deg_to_rad(60.0 * i)
		points.append(center + Vector2(cos(angle), sin(angle)) * size)
	draw_colored_polygon(points, color)


func _draw_hex_outline(center: Vector2, size: float, color: Color) -> void:
	var width := 1.0 if color.a < 0.6 else 2.5
	for i in range(6):
		var angle_a := deg_to_rad(60.0 * i)
		var angle_b := deg_to_rad(60.0 * (i + 1))
		var pa := center + Vector2(cos(angle_a), sin(angle_a)) * size
		var pb := center + Vector2(cos(angle_b), sin(angle_b)) * size
		draw_line(pa, pb, color, width)


func _draw_hex_detail(center: Vector2, size: float, code: String) -> void:
	if size < 8:
		return  # Too small to see details

	match code:
		"W":
			_draw_trees(center, size)
		"R":
			_draw_river(center, size)
		"S":
			_draw_street(center, size)
		"T":
			_draw_town(center, size)
		"C":
			_draw_city(center, size)


func _draw_trees(center: Vector2, size: float) -> void:
	var s := size * 0.25
	# Draw 3 small triangular trees
	var offsets := [Vector2(-s * 0.8, s * 0.3), Vector2(s * 0.6, s * 0.5), Vector2(0, -s * 0.5)]
	var tree_color := Color(0.2, 0.45, 0.15)
	var trunk_color := Color(0.4, 0.3, 0.15)

	for off in offsets:
		var base: Vector2 = center + off
		# Trunk
		draw_line(base + Vector2(0, s * 0.5), base + Vector2(0, s * 0.1), trunk_color, maxf(1.0, size * 0.04))
		# Canopy triangle
		var tri := PackedVector2Array([
			base + Vector2(0, -s * 0.6),
			base + Vector2(-s * 0.4, s * 0.2),
			base + Vector2(s * 0.4, s * 0.2),
		])
		draw_colored_polygon(tri, tree_color)


func _draw_river(center: Vector2, size: float) -> void:
	var water_color := Color(0.25, 0.5, 0.75, 0.7)
	var s := size * 0.6
	# Wavy line across the hex
	var points := PackedVector2Array()
	var segments := 8
	for i in range(segments + 1):
		var t := float(i) / segments
		var x := lerpf(-s, s, t)
		var y := sin(t * PI * 2.5) * s * 0.25
		points.append(center + Vector2(x, y))

	for i in range(points.size() - 1):
		draw_line(points[i], points[i + 1], water_color, maxf(2.0, size * 0.08))


func _draw_street(center: Vector2, size: float) -> void:
	var road_color := Color(0.55, 0.5, 0.4, 0.7)
	var s := size * 0.7
	# Simple line through the hex
	draw_line(center + Vector2(-s, 0), center + Vector2(s, 0), road_color, maxf(2.0, size * 0.06))


func _draw_town(center: Vector2, size: float) -> void:
	var s := size * 0.2
	var wall_color := Color(0.6, 0.4, 0.25)
	var roof_color := Color(0.7, 0.3, 0.2)

	# Small house
	var house := Rect2(center + Vector2(-s, -s * 0.2), Vector2(s * 2, s * 1.2))
	draw_rect(house, wall_color)
	# Roof
	var roof := PackedVector2Array([
		center + Vector2(-s * 1.2, -s * 0.2),
		center + Vector2(0, -s * 1.2),
		center + Vector2(s * 1.2, -s * 0.2),
	])
	draw_colored_polygon(roof, roof_color)


func _draw_city(center: Vector2, size: float) -> void:
	var s := size * 0.18
	var building_color := Color(0.5, 0.5, 0.55)
	var window_color := Color(0.85, 0.82, 0.5, 0.7)

	# Draw 2-3 buildings of varying height
	var buildings := [
		Rect2(center + Vector2(-s * 2.5, -s * 2.0), Vector2(s * 1.5, s * 3.5)),
		Rect2(center + Vector2(-s * 0.5, -s * 3.0), Vector2(s * 1.8, s * 4.5)),
		Rect2(center + Vector2(s * 1.5, -s * 1.5), Vector2(s * 1.2, s * 3.0)),
	]

	for b in buildings:
		draw_rect(b, building_color)
		# Windows
		if size > 15:
			var wx: float = b.position.x + s * 0.3
			while wx < b.position.x + b.size.x - s * 0.3:
				var wy: float = b.position.y + s * 0.4
				while wy < b.position.y + b.size.y - s * 0.4:
					draw_rect(Rect2(Vector2(wx, wy), Vector2(s * 0.3, s * 0.3)), window_color)
					wy += s * 0.8
				wx += s * 0.7


func _draw_unit_counter(center: Vector2, hex_sz: float, utype: Dictionary, uname: String, side: String = "player") -> void:
	var s := hex_sz * 0.55
	var rect := Rect2(center - Vector2(s, s * 0.6), Vector2(s * 2, s * 1.2))

	# Counter background - red tint for enemies
	var bg_color: Color = utype["icon_color"]
	if side == "enemy":
		bg_color = Color(0.8, 0.25, 0.2)
	draw_rect(rect, bg_color)

	# Counter border
	draw_rect(rect, Color(0.15, 0.1, 0.05), false, maxf(1.5, hex_sz * 0.04))

	# NATO symbol based on type
	var sym: String = utype["symbol"]
	var sym_color := Color(0.1, 0.08, 0.05)
	var line_w := maxf(1.5, hex_sz * 0.04)

	if sym == "wheeled":
		# Circle with a line underneath (wheeled vehicle)
		var circle_r := s * 0.3
		var circle_center := center + Vector2(0, -s * 0.05)
		# Draw circle as segments
		var prev := circle_center + Vector2(circle_r, 0)
		for i in range(1, 25):
			var angle := deg_to_rad(float(i) / 24.0 * 360.0)
			var next := circle_center + Vector2(cos(angle), sin(angle)) * circle_r
			draw_line(prev, next, sym_color, line_w)
			prev = next
		# Axle line
		draw_line(center + Vector2(-s * 0.5, s * 0.35), center + Vector2(s * 0.5, s * 0.35), sym_color, line_w)
		# Wheels
		var wheel_r := s * 0.1
		for wx in [-s * 0.4, s * 0.4]:
			var wc := center + Vector2(wx, s * 0.35)
			var wprev := wc + Vector2(wheel_r, 0)
			for i in range(1, 13):
				var angle := deg_to_rad(float(i) / 12.0 * 360.0)
				var wnext := wc + Vector2(cos(angle), sin(angle)) * wheel_r
				draw_line(wprev, wnext, sym_color, line_w)
				wprev = wnext

	elif sym == "infantry":
		# NATO infantry symbol: an X inside the counter
		var ix := s * 0.45
		var iy := s * 0.35
		draw_line(center + Vector2(-ix, -iy), center + Vector2(ix, iy), sym_color, line_w)
		draw_line(center + Vector2(ix, -iy), center + Vector2(-ix, iy), sym_color, line_w)

	# HQ text overlay
	if utype.get("is_hq", false) and hex_sz > 12:
		var hq_font := ThemeDB.fallback_font
		var hq_font_size := int(clampf(hex_sz * 0.25, 8, 16))
		var hq_text := "HQ"
		var hq_text_size := hq_font.get_string_size(hq_text, HORIZONTAL_ALIGNMENT_CENTER, -1, hq_font_size)
		var hq_pos := center + Vector2(-hq_text_size.x * 0.5, hq_font_size * 0.35)
		draw_string(hq_font, hq_pos, hq_text, HORIZONTAL_ALIGNMENT_LEFT, -1, hq_font_size, Color(1, 1, 1, 0.9))

	# Unit name below counter
	if hex_sz > 15:
		var font := ThemeDB.fallback_font
		var font_size := int(clampf(hex_sz * 0.22, 8, 18))
		var text_size := font.get_string_size(uname, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var text_pos := center + Vector2(-text_size.x * 0.5, s * 0.6 + font_size + 2)
		# Shadow
		draw_string(font, text_pos + Vector2(1, 1), uname, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.7))
		draw_string(font, text_pos, uname, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.95, 0.92, 0.85))


func _get_unit_at(coord: Vector2i) -> Dictionary:
	# Prefer living player units, then spotted enemies, then destroyed
	var destroyed_unit: Dictionary = {}
	for unit in units:
		if int(unit["col"]) != coord.x or int(unit["row"]) != coord.y:
			continue
		# Skip unspotted enemy units
		if unit.get("side", "player") == "enemy":
			var uname: String = unit.get("name", "")
			if uname not in spotted_enemies:
				continue
		if unit.get("unit_status", "") == "DESTROYED":
			destroyed_unit = unit
		else:
			return unit
	return destroyed_unit


func _cycle_stacked_unit() -> void:
	## Cycle to the next unit on the same hex
	var stacked: Array = []
	for u in units:
		if int(u["col"]) == selected_hex.x and int(u["row"]) == selected_hex.y:
			if u.get("unit_status", "") != "DESTROYED":
				# Skip unspotted enemies
				if u.get("side", "player") == "enemy":
					var uname: String = u.get("name", "")
					if uname not in spotted_enemies:
						continue
				stacked.append(u)
	if stacked.size() <= 1:
		return
	# Find current index and advance
	var current_name: String = selected_unit.get("name", "")
	var idx: int = 0
	for i in range(stacked.size()):
		if stacked[i].get("name", "") == current_name:
			idx = i
			break
	idx = (idx + 1) % stacked.size()
	selected_unit = stacked[idx]
	_calculate_los(selected_unit)
	_update_info_label()
	unit_panel.set_stacked_units(stacked, selected_unit.get("name", ""))


func _update_selected_unit() -> void:
	selected_unit = _get_unit_at(selected_hex)
	los_visible.clear()
	terrain_los_preview.clear()  # clear terrain LOS preview when selecting
	if not selected_unit.is_empty():
		_calculate_los(selected_unit)
		# Find stacked units on same hex
		var stacked: Array = []
		for u in units:
			if int(u["col"]) == selected_hex.x and int(u["row"]) == selected_hex.y:
				if u.get("unit_status", "") != "DESTROYED":
					stacked.append(u)
		unit_panel.set_stacked_units(stacked, selected_unit.get("name", ""))


func _show_terrain_los(screen_pos: Vector2) -> void:
	var world_pos := screen_pos / zoom_level + camera_offset / zoom_level
	var hex_coord: Vector2i = hex_grid.pixel_to_hex(world_pos)
	if not hex_grid.is_valid_hex(hex_coord):
		return

	terrain_los_origin = hex_coord
	terrain_los_preview.clear()
	var origin_elev: int = elevation_grid[hex_coord.y][hex_coord.x]

	terrain_los_preview[hex_coord] = true
	for col in range(hex_coord.x - TERRAIN_LOS_RANGE, hex_coord.x + TERRAIN_LOS_RANGE + 1):
		for row in range(hex_coord.y - TERRAIN_LOS_RANGE, hex_coord.y + TERRAIN_LOS_RANGE + 1):
			if col < 0 or col >= map_cols or row < 0 or row >= map_rows:
				continue
			var target := Vector2i(col, row)
			if target == hex_coord:
				continue
			if hex_grid.hex_distance(hex_coord, target) > TERRAIN_LOS_RANGE:
				continue
			if hex_grid.has_los(hex_coord, origin_elev, target):
				terrain_los_preview[target] = true

	# Clear unit selection to show terrain LOS instead
	selected_unit = {}
	los_visible.clear()
	selected_hex = hex_coord
	queue_redraw()


func _calculate_los(unit: Dictionary) -> void:
	los_visible.clear()
	var uc: int = unit["col"]
	var ur: int = unit["row"]
	var spot_range: int = combat_resolver.get_effective_spotting_range(unit)
	var origin := Vector2i(uc, ur)
	var origin_elev: int = elevation_grid[ur][uc]

	# The unit's own hex is always visible
	los_visible[origin] = true

	# Check every hex within spotting range
	for col in range(uc - spot_range, uc + spot_range + 1):
		for row in range(ur - spot_range, ur + spot_range + 1):
			if col < 0 or col >= map_cols or row < 0 or row >= map_rows:
				continue
			var target := Vector2i(col, row)
			if target == origin:
				continue
			if hex_grid.hex_distance(origin, target) > spot_range:
				continue
			if hex_grid.has_los(origin, origin_elev, target):
				los_visible[target] = true



func _update_info_label() -> void:
	var posture_str := Order.posture_to_string(current_posture).to_upper()
	var roe_str := Order.roe_to_string(current_roe).to_upper()
	var pursuit_str := Order.pursuit_to_string(current_pursuit).to_upper()
	var mode_str := Order.type_to_string(current_order_mode).to_upper()
	info_label.text = "Cmd+L: move  |  Cmd+R: attack  |  Right-click: unit menu  |  Space: pause"

	# Update unit carousel
	_build_carousel_order()
	_update_carousel()

	if selected_hex != Vector2i(-1, -1) and selected_hex.y < terrain_grid.size() and selected_hex.x < terrain_grid[selected_hex.y].size():
		# Show selected unit's info (use selected_unit, not _get_unit_at, to support stacked selection)
		if not selected_unit.is_empty():
			var utype_code: String = selected_unit["type_code"]
			var utype: Dictionary = unit_types.get(utype_code, {})
			# Don't show enemy orders - only show unit stats
			var order: Order = null
			var supp_val: float = 0.0
			if selected_unit.get("side", "player") == "player":
				order = order_manager.get_order(selected_unit.get("name", ""))
				supp_val = combat.get_suppression(selected_unit.get("name", ""))
			unit_panel.show_unit(selected_unit, utype, order, game_clock.game_time_minutes, supp_val)
			# Update stacked unit carousel
			var stacked: Array = []
			for u in units:
				if int(u["col"]) == selected_hex.x and int(u["row"]) == selected_hex.y:
					if u.get("unit_status", "") != "DESTROYED":
						stacked.append(u)
			unit_panel.set_stacked_units(stacked, selected_unit.get("name", ""))
		else:
			var unit := _get_unit_at(selected_hex)
			if not unit.is_empty():
				selected_unit = unit
				_calculate_los(unit)
				var utype_code: String = unit["type_code"]
				var utype: Dictionary = unit_types.get(utype_code, {})
				var order: Order = order_manager.get_order(unit.get("name", ""))
				var supp_val: float = combat.get_suppression(unit.get("name", ""))
				unit_panel.show_unit(unit, utype, order, game_clock.game_time_minutes, supp_val)
			else:
				unit_panel.hide_unit()

		pass  # hex info removed
	else:
		pass  # hex info removed
		unit_panel.hide_unit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if mb.is_command_or_control_pressed():
				if selected_unit.is_empty():
					# No unit selected - show terrain LOS preview from this hex
					_show_terrain_los(mb.position)
				else:
					_handle_move_order(mb.position)
			else:
				var world_pos := mb.position / zoom_level + camera_offset / zoom_level
				var hex_coord: Vector2i = hex_grid.pixel_to_hex(world_pos)
				if hex_grid.is_valid_hex(hex_coord):
					if hex_coord == selected_hex and not selected_unit.is_empty():
						# Same hex - cycle to next stacked unit
						_cycle_stacked_unit()
					else:
						selected_hex = hex_coord
						_update_selected_unit()
					queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed and mb.is_command_or_control_pressed():
				_handle_attack_order(mb.position)
			elif mb.pressed:
				# Check if right-clicking on a friendly unit for context menu
				var world_pos := mb.position / zoom_level + camera_offset / zoom_level
				var hex_coord: Vector2i = hex_grid.pixel_to_hex(world_pos)
				# Use already-selected unit if clicking same hex (respects stack cycling)
				var clicked_unit: Dictionary = {}
				if hex_coord == selected_hex and not selected_unit.is_empty():
					clicked_unit = selected_unit
				else:
					clicked_unit = _get_unit_at(hex_coord)
				if not clicked_unit.is_empty() and clicked_unit.get("side", "player") == "player" \
						and clicked_unit.get("unit_status", "") != "DESTROYED":
					_show_unit_context_menu(clicked_unit, mb.position)
				else:
					is_panning = true
			else:
				is_panning = false
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			is_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom(ZOOM_STEP, mb.position)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom(-ZOOM_STEP, mb.position)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if is_panning:
			camera_offset -= mm.relative
			_clamp_camera()
			queue_redraw()
		else:
			pass  # Hover highlight removed for performance

	elif event is InputEventKey and event.pressed:
		var ke := event as InputEventKey
		match ke.keycode:
			KEY_1:
				_set_game_speed(1)
			KEY_2:
				_set_game_speed(2)
			KEY_3:
				_set_game_speed(3)
			KEY_4:
				_set_game_speed(4)
			KEY_ENTER:
				_toggle_pause()
			KEY_SPACE:
				_toggle_pause()
			KEY_ESCAPE:
				_handle_escape()


func _handle_escape() -> void:
	if not selected_unit.is_empty():
		var uname: String = selected_unit.get("name", "")
		if uname != "" and order_manager.remove_last_waypoint(uname):
			_update_info_label()
			queue_redraw()
			return
	# If no waypoints to undo, deselect
	selected_hex = Vector2i(-1, -1)
	selected_unit = {}
	los_visible.clear()
	unit_panel.hide_unit()
	pass  # hex info removed
	queue_redraw()


func _build_c2_context(unit: Dictionary) -> Dictionary:
	## Build the C2 context dict for order delay calculation.
	var side: String = unit.get("side", "player")
	var in_comms: bool = unit.get("in_comms", false)
	var in_hq_los: bool = unit.get("in_hq_los", false)

	# Check if the assigned HQ is suppressed or mobile
	var hq_suppressed: bool = false
	var hq_mobile: bool = false
	var distance_to_hq: int = 999
	var assigned_hq_name: String = unit.get("assigned_hq", "")
	if assigned_hq_name != "":
		for other in units:
			if other.get("name", "") == assigned_hq_name:
				var hq_pos := Vector2i(other["col"], other["row"])
				var unit_pos := Vector2i(unit["col"], unit["row"])
				distance_to_hq = hex_grid.hex_distance(unit_pos, hq_pos)
				hq_suppressed = combat.get_suppression(assigned_hq_name) > 10
				var hq_order: Order = order_manager.get_order(assigned_hq_name)
				hq_mobile = hq_order != null and hq_order.status == Order.Status.EXECUTING
				break

	# Check if unbroken chain to top HQ exists
	var chain_intact: bool = false
	if in_comms:
		# Walk up the HQ chain
		chain_intact = true
		var current_hq_name: String = assigned_hq_name
		for _i in range(5):  # max depth
			if current_hq_name == "":
				break
			var found_hq: bool = false
			for other in units:
				if other.get("name", "") == current_hq_name:
					found_hq = true
					if other.get("unit_status", "") == "DESTROYED":
						chain_intact = false
						break
					var parent_hq: String = other.get("assigned_hq", "")
					if parent_hq == "":
						break  # Reached top HQ
					if not other.get("in_comms", false):
						chain_intact = false
					current_hq_name = parent_hq
					break
			if not found_hq:
				chain_intact = false
				break

	return {
		"side": side,
		"in_comms": in_comms,
		"in_hq_los": in_hq_los,
		"hq_suppressed": hq_suppressed,
		"hq_mobile": hq_mobile,
		"chain_intact": chain_intact,
		"distance_to_hq": distance_to_hq,
	}


func _handle_move_order(screen_pos: Vector2) -> void:
	if selected_unit.is_empty():
		return

	var world_pos := screen_pos / zoom_level + camera_offset / zoom_level
	var target: Vector2i = hex_grid.pixel_to_hex(world_pos)
	if not hex_grid.is_valid_hex(target):
		return

	var unit_pos := Vector2i(selected_unit["col"], selected_unit["row"])
	if target == unit_pos:
		return

	var utype_code: String = selected_unit["type_code"]
	var utype: Dictionary = unit_types.get(utype_code, {})

	if float(selected_unit.get("hq_switch_remaining", 0.0)) > 0:
		return  # Switching HQ, wait for connection

	# HQ units always default to hold fire, normal posture, no pursuit
	var wp_posture := current_posture
	var wp_roe := current_roe
	var wp_pursuit := current_pursuit
	if utype.get("is_hq", false):
		wp_posture = Order.Posture.NORMAL
		wp_roe = Order.ROE.HOLD_FIRE
		wp_pursuit = Order.Pursuit.HOLD
	# Use current order mode (MOVE, PATROL, or AMBUSH)
	var order_type := current_order_mode
	if order_type == Order.Type.ATTACK:
		order_type = Order.Type.MOVE  # Attack uses Cmd+Right, not Cmd+Left
	# Ambush defaults to cautious + hold fire for the approach
	if order_type == Order.Type.AMBUSH:
		wp_posture = Order.Posture.CAUTIOUS
		wp_roe = Order.ROE.HOLD_FIRE

	var c2_ctx := _build_c2_context(selected_unit)
	var order := order_manager.issue_order(
		selected_unit, utype, order_type, target,
		game_clock.game_time_minutes, wp_posture, wp_roe, wp_pursuit, c2_ctx)

	_update_info_label()
	queue_redraw()


func _handle_attack_order(screen_pos: Vector2) -> void:
	if selected_unit.is_empty():
		return
	var world_pos := screen_pos / zoom_level + camera_offset / zoom_level
	var target := hex_grid.pixel_to_hex(world_pos)
	if not hex_grid.is_valid_hex(target):
		return
	var utype_code: String = selected_unit["type_code"]
	var utype: Dictionary = unit_types.get(utype_code, {})
	if float(selected_unit.get("hq_switch_remaining", 0.0)) > 0:
		return

	# Find the best firing position
	var firing_pos := _find_firing_position(selected_unit, target)
	if firing_pos == Vector2i(-1, -1):
		return  # No valid position found

	var c2_ctx := _build_c2_context(selected_unit)
	var order := order_manager.issue_order(
		selected_unit, utype, Order.Type.ATTACK, firing_pos,
		game_clock.game_time_minutes, current_posture, Order.ROE.HALT_AND_ENGAGE,
		current_pursuit, c2_ctx)
	order.attack_target = target
	_update_info_label()
	queue_redraw()


func _find_firing_position(unit: Dictionary, target: Vector2i) -> Vector2i:
	var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
	var weapons: Array = utype.get("weapons", [])
	if not (weapons is Array) or weapons.is_empty():
		return Vector2i(-1, -1)

	# Find longest weapon effective range
	var max_range_km: float = 0.0
	for w in weapons:
		var r: float = float(w.get("range_km", 0))
		if r > max_range_km:
			max_range_km = r
	var max_range_hexes: int = int(max_range_km / 0.5)
	if max_range_hexes <= 0:
		return Vector2i(-1, -1)

	var unit_pos := Vector2i(unit["col"], unit["row"])
	var target_elev: int = elevation_grid[target.y][target.x]
	var best_pos := Vector2i(-1, -1)
	var best_score: float = -999.0

	# Evaluate hexes within weapon range of target
	for col in range(target.x - max_range_hexes, target.x + max_range_hexes + 1):
		for row in range(target.y - max_range_hexes, target.y + max_range_hexes + 1):
			if col < 0 or col >= hex_grid.map_cols or row < 0 or row >= hex_grid.map_rows:
				continue
			var pos := Vector2i(col, row)
			var dist_to_target: int = hex_grid.hex_distance(pos, target)
			if dist_to_target > max_range_hexes or dist_to_target == 0:
				continue
			# Must have LOS to target
			var pos_elev: int = elevation_grid[row][col]
			if not hex_grid.has_los(pos, pos_elev, target):
				continue

			var score: float = 0.0
			# Cover bonus
			var terrain_code: String = terrain_grid[row][col]
			match terrain_code:
				"W": score += 3.0
				"T": score += 2.0
				"C": score += 2.0
			# Can't use rivers or impassable terrain
			if terrain_code == "R":
				continue
			var t_info: Dictionary = terrain_types.get(terrain_code, {})
			if float(t_info.get("speed_modifier", 1.0)) <= 0.0:
				continue
			# Elevation advantage
			score += float(pos_elev - target_elev) * 1.0
			# Prefer closer to current position (less travel time)
			var dist_from_unit: int = hex_grid.hex_distance(unit_pos, pos)
			score -= float(dist_from_unit) * 0.3
			# Prefer being at optimal range (not too close)
			if dist_to_target >= 2:
				score += 1.0  # some standoff is good

			if score > best_score:
				best_score = score
				best_pos = pos

	return best_pos


func _zoom(step: float, mouse_pos: Vector2) -> void:
	var old_zoom := zoom_level
	zoom_level = clampf(zoom_level + step, ZOOM_MIN, ZOOM_MAX)
	if zoom_level == old_zoom:
		return
	var world_before := mouse_pos / old_zoom + camera_offset / old_zoom
	var world_after := mouse_pos / zoom_level + camera_offset / zoom_level
	camera_offset += (world_before - world_after) * zoom_level
	_clamp_camera()
	queue_redraw()


func _clamp_camera() -> void:
	var map_pixel_width := (map_cols - 1) * hex_width * 0.75 + hex_width
	var map_pixel_height := (map_rows - 1) * hex_height + hex_height
	var viewport_size := get_viewport_rect().size
	var max_x := map_pixel_width * zoom_level - viewport_size.x + hex_size * zoom_level
	var max_y := map_pixel_height * zoom_level - viewport_size.y + hex_size * zoom_level
	camera_offset.x = clampf(camera_offset.x, -hex_size * zoom_level, max_x)
	camera_offset.y = clampf(camera_offset.y, -hex_size * zoom_level, max_y)


