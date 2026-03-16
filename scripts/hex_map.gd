extends Node2D

# Set before adding to scene tree
var map_file: String = ""

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

# Cached posture configs
var posture_configs: Dictionary = {}

# Camera
var camera_offset := Vector2.ZERO
var is_panning := false
var zoom_level := 1.0
const ZOOM_MIN := 0.2
const ZOOM_MAX := 3.0
const ZOOM_STEP := 0.15

# Edge scrolling
const EDGE_SCROLL_MARGIN := 20.0
const EDGE_SCROLL_SPEED := 300.0

# Ammo burn rates: rounds consumed per weapon per game-minute
# Keyed by ROE name.  Hold Fire is always 0.
const AMMO_BURN_FIRE_AT_WILL: float = 15.0    # continuous suppressive fire
const AMMO_BURN_RETURN_FIRE: float = 5.0       # reactive bursts
const AMMO_BURN_HALT_AND_ENGAGE: float = 20.0  # heavy focused fire (only when stopped)

# Morale thresholds
const MORALE_BREAK_THRESHOLD: int = 3
const MORALE_ROUT_THRESHOLD: int = 2

# Selection highlight
const COLOR_SELECT_OUTLINE := Color(0.7, 0.3, 0.9, 0.9)
const COLOR_HOVER_OUTLINE := Color(1.0, 1.0, 1.0, 0.5)

# UI
var info_label: Label
var hex_panel: PanelContainer
var panel_coord_label: Label
var panel_terrain_label: Label
var panel_elevation_label: Label
var panel_speed_modifier_label: Label
var unit_panel: UnitPanel
var game_clock: GameClock
var game_flow_panel: GameFlowPanel
var order_manager: OrderManager


func _ready() -> void:
	_load_terrain_types()
	_load_unit_types()
	_load_display_config()
	_load_map()
	_place_starting_units()
	_setup_info_label()
	_setup_hex_panel()
	_setup_unit_panel()
	_setup_game_flow()
	camera_offset = Vector2(-100, -50)


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
	# Place a technical on an open or street hex near the center
	var center_col := map_cols / 2
	var center_row := map_rows / 2
	# Search outward from center for a suitable hex
	for radius in range(0, 10):
		for dc in range(-radius, radius + 1):
			for dr in range(-radius, radius + 1):
				var c := center_col + dc
				var r := center_row + dr
				if c >= 0 and c < map_cols and r >= 0 and r < map_rows:
					var code: String = terrain_grid[r][c]
					if code == "O" or code == "S":
						var unit_dict: Dictionary = {
							"type_code": "TEC",
							"col": c,
							"row": r,
							"name": "Technical 1",
						}
						_init_unit_ammo_and_morale(unit_dict)
						units.append(unit_dict)
						return


func _init_unit_ammo_and_morale(unit: Dictionary) -> void:
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var weapons: Array = utype.get("weapons", [])
	var ammo_array: Array = []
	for w in weapons:
		ammo_array.append(int(w.get("ammo", 0)))
	unit["current_ammo"] = ammo_array
	unit["current_morale"] = int(utype.get("morale", 5))
	unit["unit_status"] = ""  # "", "BROKEN", "ROUTING"


func _get_effective_roe(unit: Dictionary, order: Order) -> Order.ROE:
	# If unit is broken or routing, effective ROE is hold fire
	var status: String = unit.get("unit_status", "")
	if status == "BROKEN" or status == "ROUTING":
		return Order.ROE.HOLD_FIRE
	# If all weapons empty, effective ROE is hold fire
	var ammo_arr: Array = unit.get("current_ammo", [])
	var all_empty: bool = true
	for a in ammo_arr:
		if int(a) > 0:
			all_empty = false
			break
	if all_empty and ammo_arr.size() > 0:
		return Order.ROE.HOLD_FIRE
	if order == null:
		return Order.ROE.RETURN_FIRE
	return order.roe


func _consume_ammo(unit: Dictionary, minutes: float) -> void:
	var uname: String = unit.get("name", "")
	var order: Order = order_manager.get_order(uname)
	var roe: Order.ROE = _get_effective_roe(unit, order)

	# Hold fire: never shoot
	if roe == Order.ROE.HOLD_FIRE:
		return

	# Find enemies in range and LOS
	var targets := _find_targets_in_range(unit)
	if targets.is_empty():
		return  # Nothing to shoot at

	# Halt & Engage only fires when the unit is stopped
	if roe == Order.ROE.HALT_AND_ENGAGE:
		if order != null and order.status == Order.Status.EXECUTING:
			return

	# Return Fire only fires if an enemy can also see us (proxy for "being fired upon")
	if roe == Order.ROE.RETURN_FIRE:
		var being_engaged := false
		for target in targets:
			var t_order: Order = order_manager.get_order(target.get("name", ""))
			var t_roe: Order.ROE = _get_effective_roe(target, t_order)
			if t_roe == Order.ROE.FIRE_AT_WILL or t_roe == Order.ROE.HALT_AND_ENGAGE:
				being_engaged = true
				break
		if not being_engaged:
			return

	var burn_rate: float = 0.0
	match roe:
		Order.ROE.FIRE_AT_WILL:
			burn_rate = AMMO_BURN_FIRE_AT_WILL
		Order.ROE.RETURN_FIRE:
			burn_rate = AMMO_BURN_RETURN_FIRE
		Order.ROE.HALT_AND_ENGAGE:
			burn_rate = AMMO_BURN_HALT_AND_ENGAGE

	var ammo_arr: Array = unit.get("current_ammo", [])
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var weapons: Array = utype.get("weapons", [])
	var consumed_any: bool = false

	for i in range(ammo_arr.size()):
		var current: int = int(ammo_arr[i])
		if current <= 0:
			continue
		# Only fire weapons that have targets in their range
		var w_range_km: float = float(weapons[i].get("range_km", 0))
		var is_moving := order != null and order.status == Order.Status.EXECUTING
		if is_moving:
			w_range_km = float(weapons[i].get("range_moving_km", w_range_km * 0.3))
		var w_range_hexes: float = w_range_km / 0.5
		var unit_pos := Vector2i(unit["col"], unit["row"])
		var has_target := false
		for target in targets:
			var t_pos := Vector2i(target["col"], target["row"])
			if float(_hex_distance(unit_pos, t_pos)) <= w_range_hexes:
				has_target = true
				break
		if not has_target:
			continue

		var rof: float = 600.0
		if i < weapons.size():
			rof = float(weapons[i].get("rate_of_fire", 600))
		var rof_scale: float = rof / 600.0
		var consumed: float = burn_rate * rof_scale * minutes
		var new_ammo: int = maxi(0, current - int(consumed))
		ammo_arr[i] = new_ammo
		if new_ammo < current:
			consumed_any = true

	unit["current_ammo"] = ammo_arr
	if consumed_any:
		_check_morale(unit)


func _find_targets_in_range(unit: Dictionary) -> Array:
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var unit_pos := Vector2i(unit["col"], unit["row"])
	var unit_side: String = unit.get("side", "player")
	var spot_range: int = int(utype.get("spotting_range", 4))
	var unit_elev: int = elevation_grid[unit_pos.y][unit_pos.x]

	var targets: Array = []
	for other in units:
		if other.get("side", "player") == unit_side:
			continue
		var other_pos := Vector2i(other["col"], other["row"])
		if _hex_distance(unit_pos, other_pos) > spot_range:
			continue
		if _has_los(unit_pos, unit_elev, other_pos):
			targets.append(other)
	return targets


func _get_lowest_ammo_pct(unit: Dictionary) -> float:
	var ammo_arr: Array = unit.get("current_ammo", [])
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var weapons: Array = utype.get("weapons", [])
	if ammo_arr.is_empty():
		return 1.0
	var lowest: float = 1.0
	for i in range(ammo_arr.size()):
		var max_ammo: int = 0
		if i < weapons.size():
			max_ammo = int(weapons[i].get("ammo", 0))
		if max_ammo <= 0:
			continue
		var pct: float = float(int(ammo_arr[i])) / float(max_ammo)
		if pct < lowest:
			lowest = pct
	return lowest


func _get_ammo_morale_penalty(unit: Dictionary) -> int:
	var ammo_arr: Array = unit.get("current_ammo", [])
	# Check if ALL weapons are empty
	var all_empty: bool = true
	for a in ammo_arr:
		if int(a) > 0:
			all_empty = false
			break
	if all_empty and ammo_arr.size() > 0:
		return 3
	var lowest_pct: float = _get_lowest_ammo_pct(unit)
	if lowest_pct < 0.25:
		return 2
	elif lowest_pct < 0.50:
		return 1
	return 0


func _check_morale(unit: Dictionary) -> void:
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var base_morale: int = int(utype.get("morale", 5))
	var penalty: int = _get_ammo_morale_penalty(unit)
	var effective_morale: int = maxi(0, base_morale - penalty)
	unit["current_morale"] = effective_morale

	var status: String = unit.get("unit_status", "")
	if effective_morale < MORALE_ROUT_THRESHOLD and status != "ROUTING":
		unit["unit_status"] = "ROUTING"
		_start_rout(unit)
	elif effective_morale < MORALE_BREAK_THRESHOLD and status != "ROUTING" and status != "BROKEN":
		unit["unit_status"] = "BROKEN"
		_start_break(unit)


func _start_break(unit: Dictionary) -> void:
	var uname: String = unit.get("name", "")
	# Cancel current order
	order_manager.cancel_order(uname)
	# Issue a withdraw order toward the nearest map edge
	var edge_hex: Vector2i = _nearest_edge_hex(Vector2i(unit["col"], unit["row"]))
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	order_manager.issue_order(unit, utype, Order.Type.WITHDRAW, edge_hex,
		game_clock.game_time_minutes, Order.Posture.CAUTIOUS, Order.ROE.HOLD_FIRE)


func _start_rout(unit: Dictionary) -> void:
	var uname: String = unit.get("name", "")
	# Cancel current order
	order_manager.cancel_order(uname)
	# Issue a fast withdraw toward the nearest map edge
	var edge_hex: Vector2i = _nearest_edge_hex(Vector2i(unit["col"], unit["row"]))
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	order_manager.issue_order(unit, utype, Order.Type.WITHDRAW, edge_hex,
		game_clock.game_time_minutes, Order.Posture.FAST, Order.ROE.HOLD_FIRE)


func _nearest_edge_hex(pos: Vector2i) -> Vector2i:
	# Find closest map edge hex
	var dist_left: int = pos.x
	var dist_right: int = map_cols - 1 - pos.x
	var dist_top: int = pos.y
	var dist_bottom: int = map_rows - 1 - pos.y
	var min_dist: int = dist_left
	var best: Vector2i = Vector2i(0, pos.y)
	if dist_right < min_dist:
		min_dist = dist_right
		best = Vector2i(map_cols - 1, pos.y)
	if dist_top < min_dist:
		min_dist = dist_top
		best = Vector2i(pos.x, 0)
	if dist_bottom < min_dist:
		best = Vector2i(pos.x, map_rows - 1)
	return best


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


func _setup_info_label() -> void:
	info_label = Label.new()
	info_label.position = Vector2(10, 10)
	info_label.add_theme_font_size_override("font_size", 16)
	info_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	info_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	info_label.add_theme_constant_override("shadow_offset_x", 1)
	info_label.add_theme_constant_override("shadow_offset_y", 1)
	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)
	ui_layer.add_child(info_label)


func _setup_hex_panel() -> void:
	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)

	# Panel container anchored bottom-right
	hex_panel = PanelContainer.new()
	hex_panel.custom_minimum_size = Vector2(260, 0)
	hex_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	# Style: black background with slight transparency
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.05, 0.88)
	style.border_color = Color(0.35, 0.38, 0.3, 0.6)
	style.border_width_top = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_left = 2
	style.corner_radius_bottom_right = 2
	hex_panel.add_theme_stylebox_override("panel", style)

	# Use a Control wrapper for anchoring
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	anchor.offset_left = -290
	anchor.offset_top = -200
	anchor.offset_right = -6
	anchor.offset_bottom = -6
	anchor.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	anchor.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ui_layer.add_child(anchor)
	anchor.add_child(hex_panel)
	hex_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hex_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hex_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	hex_panel.add_child(vbox)

	# Header
	var header := Label.new()
	header.text = "HEX INFO"
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color(0.5, 0.55, 0.45))
	vbox.add_child(header)

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Color(0.3, 0.32, 0.25, 0.5))
	vbox.add_child(sep)

	# Labels
	panel_coord_label = _make_panel_label()
	vbox.add_child(panel_coord_label)

	panel_terrain_label = _make_panel_label()
	vbox.add_child(panel_terrain_label)

	panel_elevation_label = _make_panel_label()
	vbox.add_child(panel_elevation_label)

	panel_speed_modifier_label = _make_panel_label()
	vbox.add_child(panel_speed_modifier_label)

	hex_panel.visible = false


func _setup_unit_panel() -> void:
	unit_panel = UnitPanel.new()
	add_child(unit_panel)
	unit_panel.order_cleared.connect(_on_order_cleared)
	unit_panel.posture_changed.connect(_on_posture_changed)
	unit_panel.roe_changed.connect(_on_roe_changed)


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

	game_clock.time_advanced.connect(_on_time_advanced)
	game_clock.phase_changed.connect(_on_phase_changed)

	game_flow_panel = GameFlowPanel.new()
	add_child(game_flow_panel)
	game_flow_panel.set_clock(game_clock)


func _on_phase_changed(phase: String) -> void:
	unit_panel.set_orders_phase(phase == "ORDERS")


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


func _on_order_cleared(unit_name: String) -> void:
	order_manager.cancel_order(unit_name)
	_update_info_label()
	queue_redraw()


func _on_time_advanced(minutes: float) -> void:
	order_manager.update_orders(game_clock.game_time_minutes)
	_move_units(minutes)
	# Consume ammo and check morale for all units
	for unit in units:
		_consume_ammo(unit, minutes)
	# Keep selection tracking the selected unit
	if not selected_unit.is_empty():
		selected_hex = Vector2i(selected_unit["col"], selected_unit["row"])
		_update_info_label()
	queue_redraw()


func _move_units(minutes: float) -> void:
	for unit in units:
		var uname: String = unit["name"]
		var order: Order = order_manager.get_order(uname)
		if order == null or order.status != Order.Status.EXECUTING:
			continue

		var utype_code: String = unit["type_code"]
		var utype: Dictionary = unit_types.get(utype_code, {})
		var speed_kmh: float = float(utype.get("speed_kmh", 40))

		# Apply posture speed modifier
		var posture_str := Order.posture_to_string(order.posture)
		var posture_cfg: Dictionary = posture_configs.get(posture_str, {})
		var posture_speed_mod: float = posture_cfg.get("speed_modifier", 1.0)

		# Get terrain speed modifier for current hex
		var cur_terrain: String = terrain_grid[unit["row"]][unit["col"]]
		var terrain_speed_mod: float = 1.0
		if cur_terrain in terrain_types:
			terrain_speed_mod = float(terrain_types[cur_terrain].get("speed_modifier", 1.0))

		if terrain_speed_mod <= 0.0:
			continue  # impassable

		# Effective speed in km/h
		var effective_speed := speed_kmh * posture_speed_mod * terrain_speed_mod
		# Distance covered this tick in km
		var distance_km := effective_speed * (minutes / 60.0)
		# Each hex is 0.5 km
		var hexes_moved := distance_km / 0.5

		# Accumulate fractional movement
		if not "move_accumulator" in unit:
			unit["move_accumulator"] = 0.0
		unit["move_accumulator"] = float(unit["move_accumulator"]) + hexes_moved

		# Step toward current waypoint one hex at a time
		while float(unit["move_accumulator"]) >= 1.0:
			var current := Vector2i(unit["col"], unit["row"])
			var target := order.current_target()

			if target == Vector2i(-1, -1):
				order.status = Order.Status.COMPLETE
				unit["move_accumulator"] = 0.0
				break

			if current == target:
				# Reached current waypoint - advance to next
				if not order.advance_waypoint():
					order.status = Order.Status.COMPLETE
					unit["move_accumulator"] = 0.0
					break
				# Update posture for new waypoint
				posture_str = Order.posture_to_string(order.posture)
				posture_cfg = posture_configs.get(posture_str, {})
				posture_speed_mod = posture_cfg.get("speed_modifier", 1.0)
				continue

			# Find next hex toward current waypoint
			var unit_training: String = str(utype.get("training", "regular"))
			var unit_morale: int = int(utype.get("morale", 5))
			var next_hex := _next_step_toward(current, target, posture_str, unit_training, unit_morale)

			# Hesitation: low morale/poorly trained units in cover may stall
			# before moving into open ground
			var cur_terrain_code: String = terrain_grid[current.y][current.x]
			var next_terrain: String = terrain_grid[next_hex.y][next_hex.x]
			var in_cover := cur_terrain_code == "W" or cur_terrain_code == "T"
			var leaving_cover := in_cover and (next_terrain == "O" or next_terrain == "S")
			if leaving_cover and posture_str == "cautious":
				if not "hesitate_until" in unit:
					# Roll for hesitation based on training/morale
					var hesitate_chance := 0.0
					match unit_training:
						"militia": hesitate_chance = 0.6
						"irregular": hesitate_chance = 0.4
						"regular": hesitate_chance = 0.1
					hesitate_chance *= clampf((6.0 - unit_morale) / 5.0, 0.0, 1.0)
					if randf() < hesitate_chance:
						# Stall for 15-60 minutes
						var stall_minutes := randf_range(15.0, 60.0)
						unit["hesitate_until"] = game_clock.game_time_minutes + stall_minutes
						unit["move_accumulator"] = 0.0
						break
				else:
					if game_clock.game_time_minutes < float(unit["hesitate_until"]):
						unit["move_accumulator"] = 0.0
						break
					else:
						unit.erase("hesitate_until")
			var next_speed_mod: float = 1.0
			if next_terrain in terrain_types:
				next_speed_mod = float(terrain_types[next_terrain].get("speed_modifier", 1.0))

			if next_speed_mod <= 0.0:
				order.status = Order.Status.COMPLETE
				unit["move_accumulator"] = 0.0
				break

			unit["col"] = next_hex.x
			unit["row"] = next_hex.y
			unit["move_accumulator"] = float(unit["move_accumulator"]) - 1.0

			# Update LOS if this is the selected unit
			if not selected_unit.is_empty() and selected_unit.get("name", "") == uname:
				selected_unit = unit
				_calculate_los(unit)


func _next_step_toward(from: Vector2i, to: Vector2i, posture_name: String = "normal",
		_training: String = "regular", _morale: int = 5) -> Vector2i:
	var neighbors := _get_hex_neighbors(from)
	var best := from
	var best_score := 999999.0
	var pcfg: Dictionary = posture_configs.get(posture_name, {})
	var road_pref: float = pcfg.get("road_preference", 1.0)
	var cover_pref: float = pcfg.get("cover_preference", 0.5)

	for n in neighbors:
		if n.x < 0 or n.x >= map_cols or n.y < 0 or n.y >= map_rows:
			continue

		var dist := float(_hex_distance(n, to))
		var cur_dist := float(_hex_distance(from, to))
		# Must make progress or move sideways (never backwards)
		if dist > cur_dist:
			continue

		var n_terrain: String = terrain_grid[n.y][n.x]
		var t_info: Dictionary = terrain_types.get(n_terrain, {})
		var speed_mod: float = float(t_info.get("speed_modifier", 1.0))

		if speed_mod <= 0.0:
			continue  # impassable

		# Distance always dominates - multiply by 10 so preferences
		# can only matter as tie-breakers between equal-distance neighbors.
		# Discipline scales how strong the tie-breaking preference is.
		var cost := dist * 10.0

		if n_terrain == "S":
			cost -= road_pref * 0.4
		if n_terrain == "W" or n_terrain == "T":
			cost -= cover_pref * 0.4
		if n_terrain == "O":
			cost += cover_pref * 0.2

		if cost < best_score:
			best_score = cost
			best = n

	return best


func _get_hex_neighbors(hex: Vector2i) -> Array[Vector2i]:
	var col := hex.x
	var row := hex.y
	var parity := col & 1
	var neighbors: Array[Vector2i] = []

	if parity == 0:
		neighbors.append(Vector2i(col + 1, row - 1))
		neighbors.append(Vector2i(col + 1, row))
		neighbors.append(Vector2i(col, row + 1))
		neighbors.append(Vector2i(col - 1, row))
		neighbors.append(Vector2i(col - 1, row - 1))
		neighbors.append(Vector2i(col, row - 1))
	else:
		neighbors.append(Vector2i(col + 1, row))
		neighbors.append(Vector2i(col + 1, row + 1))
		neighbors.append(Vector2i(col, row + 1))
		neighbors.append(Vector2i(col - 1, row + 1))
		neighbors.append(Vector2i(col - 1, row))
		neighbors.append(Vector2i(col, row - 1))

	return neighbors


func _make_panel_label() -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.82, 0.84, 0.78))
	return label


func _process(delta: float) -> void:
	var viewport_size := get_viewport_rect().size
	var mouse_pos := get_viewport().get_mouse_position()

	# Edge scrolling
	var scroll_dir := Vector2.ZERO
	var in_window := mouse_pos.x >= 0 and mouse_pos.y >= 0 \
		and mouse_pos.x <= viewport_size.x and mouse_pos.y <= viewport_size.y

	if in_window:
		if mouse_pos.x < EDGE_SCROLL_MARGIN:
			scroll_dir.x = -1
		elif mouse_pos.x > viewport_size.x - EDGE_SCROLL_MARGIN:
			scroll_dir.x = 1
		if mouse_pos.y < EDGE_SCROLL_MARGIN:
			scroll_dir.y = -1
		elif mouse_pos.y > viewport_size.y - EDGE_SCROLL_MARGIN:
			scroll_dir.y = 1

	if scroll_dir != Vector2.ZERO:
		camera_offset += scroll_dir * EDGE_SCROLL_SPEED * delta / zoom_level
		_clamp_camera()
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
			var center := (_hex_to_pixel(col, row) - camera_offset / zoom_level) * zoom_level
			var code: String = terrain_grid[row][col]
			var elev: int = elevation_grid[row][col] if row < elevation_grid.size() and col < elevation_grid[row].size() else 5

			# Get base color from terrain type
			var base_color := Color(0.8, 0.8, 0.8)
			if code in terrain_types:
				base_color = terrain_types[code]["color"]

			# Apply elevation shading
			var shade := lerpf(elev_min_shade, elev_max_shade, elev / 9.0)
			var color := Color(
				clampf(base_color.r + shade, 0, 1),
				clampf(base_color.g + shade, 0, 1),
				clampf(base_color.b + shade, 0, 1)
			)

			_draw_hex_filled(center, scaled_size, color)
			_draw_hex_detail(center, scaled_size, code)

			# Outline
			var outline_color := Color(0.3, 0.35, 0.25, 0.4)
			if Vector2i(col, row) == selected_hex:
				outline_color = COLOR_SELECT_OUTLINE
			elif Vector2i(col, row) == hovered_hex:
				outline_color = COLOR_HOVER_OUTLINE

			_draw_hex_outline(center, scaled_size, outline_color)

	# Draw LOS overlay when a unit is selected
	if not selected_unit.is_empty() and not los_visible.is_empty():
		for col in range(min_col, max_col + 1):
			for row in range(min_row, max_row + 1):
				var coord := Vector2i(col, row)
				var center := (_hex_to_pixel(col, row) - camera_offset / zoom_level) * zoom_level
				if coord in los_visible:
					# Visible: light green tint
					_draw_hex_filled(center, scaled_size * 0.92, Color(0.3, 0.9, 0.3, 0.12))
				else:
					# Check if within spotting range but not visible
					var unit_coord := Vector2i(selected_unit["col"], selected_unit["row"])
					if _hex_distance(unit_coord, coord) <= unit_types[selected_unit["type_code"]]["spotting_range"]:
						# In range but blocked: dim red
						_draw_hex_filled(center, scaled_size * 0.92, Color(0.9, 0.2, 0.1, 0.15))

	# Draw weapon range rings when a unit is selected
	if not selected_unit.is_empty():
		var utype_code: String = selected_unit["type_code"]
		if utype_code in unit_types:
			var utype: Dictionary = unit_types[utype_code]
			var weapons = utype.get("weapons", [])
			var unit_pos := Vector2i(selected_unit["col"], selected_unit["row"])
			var unit_screen := (_hex_to_pixel(unit_pos.x, unit_pos.y) - camera_offset / zoom_level) * zoom_level

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
				var w: Dictionary = weapons[wi]
				var range_static: float = float(w.get("range_km", 0))
				var range_moving: float = float(w.get("range_moving_km", range_static * 0.3))
				var range_km: float = range_moving if is_moving else range_static
				var range_hexes: float = range_km / 0.5
				var ring_color: Color = ring_colors[wi % ring_colors.size()]
				var ring_radius := range_hexes * hex_height * zoom_level

				# Draw ring as segmented circle - dashed when moving
				var segments := 48
				var line_w := maxf(1.5, scaled_size * 0.04)
				for i in range(segments):
					if is_moving and i % 3 == 0:
						continue  # dashed when moving
					var a0 := deg_to_rad(float(i) / segments * 360.0)
					var a1 := deg_to_rad(float(i + 1) / segments * 360.0)
					var p0 := unit_screen + Vector2(cos(a0), sin(a0)) * ring_radius
					var p1 := unit_screen + Vector2(cos(a1), sin(a1)) * ring_radius
					draw_line(p0, p1, ring_color, line_w)

				# Label the ring
				if scaled_size > 10:
					var font := ThemeDB.fallback_font
					var wname: String = w.get("name", "?")
					var move_tag := " MOV" if is_moving else ""
					var label_text := "%s (%.1fkm%s)" % [wname, range_km, move_tag]
					var font_size := int(clampf(scaled_size * 0.18, 8, 13))
					var label_pos := unit_screen + Vector2(ring_radius + 4, -font_size * 0.5 - wi * (font_size + 2))
					draw_string(font, label_pos + Vector2(1, 1), label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.6))
					draw_string(font, label_pos, label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ring_color)

	# Draw order waypoint lines and markers
	for unit in units:
		var uname: String = unit["name"]
		var order: Order = order_manager.get_order(uname)
		if order == null or order.status == Order.Status.COMPLETE or order.status == Order.Status.COUNTERMANDED:
			continue
		if order.waypoints.is_empty():
			continue

		var is_dashed := order.status != Order.Status.EXECUTING
		var line_w := maxf(2.0, scaled_size * 0.05)

		# Start from unit position
		var prev_screen := (_hex_to_pixel(unit["col"], unit["row"]) - camera_offset / zoom_level) * zoom_level

		for wi in range(order.waypoints.size()):
			var wp: Dictionary = order.waypoints[wi]
			var wp_hex: Vector2i = wp["hex"]
			var wp_posture: Order.Posture = wp["posture"]
			var wp_screen := (_hex_to_pixel(wp_hex.x, wp_hex.y) - camera_offset / zoom_level) * zoom_level

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

	# Draw units on top
	for unit in units:
		var uc: int = unit["col"]
		var ur: int = unit["row"]
		if uc >= min_col and uc <= max_col and ur >= min_row and ur <= max_row:
			var center := (_hex_to_pixel(uc, ur) - camera_offset / zoom_level) * zoom_level
			var type_code: String = unit["type_code"]
			if type_code in unit_types:
				_draw_unit_counter(center, scaled_size, unit_types[type_code], unit["name"])


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


func _draw_unit_counter(center: Vector2, hex_sz: float, utype: Dictionary, uname: String) -> void:
	var s := hex_sz * 0.55
	var rect := Rect2(center - Vector2(s, s * 0.6), Vector2(s * 2, s * 1.2))

	# Counter background
	var bg_color: Color = utype["icon_color"]
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
	for unit in units:
		if unit["col"] == coord.x and unit["row"] == coord.y:
			return unit
	return {}


func _update_selected_unit() -> void:
	selected_unit = _get_unit_at(selected_hex)
	los_visible.clear()
	if not selected_unit.is_empty():
		_calculate_los(selected_unit)


func _calculate_los(unit: Dictionary) -> void:
	los_visible.clear()
	var uc: int = unit["col"]
	var ur: int = unit["row"]
	var type_code: String = unit["type_code"]
	var spot_range: int = unit_types[type_code]["spotting_range"] if type_code in unit_types else 4
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
			if _hex_distance(origin, target) > spot_range:
				continue
			if _has_los(origin, origin_elev, target):
				los_visible[target] = true


func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	# Convert offset coords to cube coords then compute distance
	var ac := _offset_to_cube(a)
	var bc := _offset_to_cube(b)
	return (absi(ac.x - bc.x) + absi(ac.y - bc.y) + absi(ac.z - bc.z)) / 2


func _offset_to_cube(hex: Vector2i) -> Vector3i:
	var q := hex.x
	var r := hex.y - (hex.x - (hex.x & 1)) / 2
	var s := -q - r
	return Vector3i(q, r, s)


func _cube_to_offset(cube: Vector3i) -> Vector2i:
	var col := cube.x
	var row := cube.y + (cube.x - (cube.x & 1)) / 2
	return Vector2i(col, row)


func _has_los(origin: Vector2i, origin_elev: int, target: Vector2i) -> bool:
	# Walk a line from origin to target in cube coords, check each intermediate hex
	var oc := _offset_to_cube(origin)
	var tc := _offset_to_cube(target)
	var dist := _hex_distance(origin, target)
	if dist <= 1:
		return true

	var target_elev: int = elevation_grid[target.y][target.x]

	# Lerp through cube coords
	for step in range(1, dist):
		var t := float(step) / float(dist)
		var fq := lerpf(float(oc.x) + 1e-6, float(tc.x) + 1e-6, t)
		var fr := lerpf(float(oc.y) + 1e-6, float(tc.y) + 1e-6, t)
		var fs := lerpf(float(oc.z) - 2e-6, float(tc.z) - 2e-6, t)
		var cube := _cube_round(fq, fr, fs)
		var hex := _cube_to_offset(cube)

		if hex.x < 0 or hex.x >= map_cols or hex.y < 0 or hex.y >= map_rows:
			return false

		var mid_elev: int = elevation_grid[hex.y][hex.x]
		var mid_terrain: String = terrain_grid[hex.y][hex.x]
		var hex_dist_from_origin := _hex_distance(origin, hex)

		# Elevation blocking
		var expected_elev := lerpf(float(origin_elev), float(target_elev), t)
		if float(mid_elev) > expected_elev + 0.5:
			return false

		# Terrain blocking - adjacent hexes (distance 1) never block,
		# you can see into the tree line but not through it
		if hex_dist_from_origin <= 1:
			continue

		if mid_terrain == "W" or mid_terrain == "C":
			if origin_elev < mid_elev + 2:
				return false
		elif mid_terrain == "T":
			if origin_elev < mid_elev + 1:
				return false

	return true


func _cube_round(fq: float, fr: float, fs: float) -> Vector3i:
	var q := roundi(fq)
	var r := roundi(fr)
	var s := roundi(fs)
	var q_diff := absf(float(q) - fq)
	var r_diff := absf(float(r) - fr)
	var s_diff := absf(float(s) - fs)
	if q_diff > r_diff and q_diff > s_diff:
		q = -r - s
	elif r_diff > s_diff:
		r = -q - s
	else:
		s = -q - r
	return Vector3i(q, r, s)


func _update_info_label() -> void:
	var posture_str := Order.posture_to_string(current_posture).to_upper()
	var roe_str := Order.roe_to_string(current_roe).to_upper()
	info_label.text = "%s (1/2/3)  |  %s (Q/W/E/R)  |  Cmd+Click: waypoint  |  ESC: undo" % [posture_str, roe_str]

	if selected_hex != Vector2i(-1, -1) and selected_hex.y < terrain_grid.size() and selected_hex.x < terrain_grid[selected_hex.y].size():
		var code: String = terrain_grid[selected_hex.y][selected_hex.x]
		var elev: int = elevation_grid[selected_hex.y][selected_hex.x]
		var tname: String = terrain_types[code]["name"] if code in terrain_types else "unknown"
		var mcost: float = terrain_types[code]["speed_modifier"] if code in terrain_types else 1.0

		panel_coord_label.text = "Coord:     %d, %d" % [selected_hex.x, selected_hex.y]
		panel_terrain_label.text = "Terrain:   %s" % tname
		panel_elevation_label.text = "Elevation: %d" % elev
		panel_speed_modifier_label.text = "Speed:     %d%%" % int(mcost * 100)

		# Check for unit on this hex
		var unit := _get_unit_at(selected_hex)
		if not unit.is_empty():
			var utype_code: String = unit["type_code"]
			var utype: Dictionary = unit_types.get(utype_code, {})
			var order: Order = order_manager.get_order(unit.get("name", ""))
			unit_panel.show_unit(unit, utype, order, game_clock.game_time_minutes)
		else:
			unit_panel.hide_unit()

		hex_panel.visible = true
	else:
		hex_panel.visible = false
		unit_panel.hide_unit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if mb.is_command_or_control_pressed():
				_handle_move_order(mb.position)
			else:
				var world_pos := mb.position / zoom_level + camera_offset / zoom_level
				var hex_coord := _pixel_to_hex(world_pos)
				if _is_valid_hex(hex_coord):
					selected_hex = hex_coord
					_update_selected_unit()
					queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			is_panning = mb.pressed
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
			var world_pos := mm.position / zoom_level + camera_offset / zoom_level
			var hex_coord := _pixel_to_hex(world_pos)
			if hex_coord != hovered_hex:
				hovered_hex = hex_coord if _is_valid_hex(hex_coord) else Vector2i(-1, -1)
				queue_redraw()

	elif event is InputEventKey and event.pressed:
		var ke := event as InputEventKey
		match ke.keycode:
			KEY_1:
				current_posture = Order.Posture.FAST
				_update_info_label()
				queue_redraw()
			KEY_2:
				current_posture = Order.Posture.NORMAL
				_update_info_label()
				queue_redraw()
			KEY_3:
				current_posture = Order.Posture.CAUTIOUS
				_update_info_label()
				queue_redraw()
			KEY_Q:
				current_roe = Order.ROE.HOLD_FIRE
				_update_info_label()
			KEY_W:
				current_roe = Order.ROE.RETURN_FIRE
				_update_info_label()
			KEY_E:
				current_roe = Order.ROE.FIRE_AT_WILL
				_update_info_label()
			KEY_R:
				current_roe = Order.ROE.HALT_AND_ENGAGE
				_update_info_label()
			KEY_SPACE:
				if game_clock.is_orders_phase():
					game_clock.end_orders_phase()
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
	hex_panel.visible = false
	queue_redraw()


func _handle_move_order(screen_pos: Vector2) -> void:
	if not game_clock.is_orders_phase():
		return
	if selected_unit.is_empty():
		return

	var world_pos := screen_pos / zoom_level + camera_offset / zoom_level
	var target := _pixel_to_hex(world_pos)
	if not _is_valid_hex(target):
		return

	var unit_pos := Vector2i(selected_unit["col"], selected_unit["row"])
	if target == unit_pos:
		return

	var utype_code: String = selected_unit["type_code"]
	var utype: Dictionary = unit_types.get(utype_code, {})

	var order := order_manager.issue_order(
		selected_unit, utype, Order.Type.MOVE, target,
		game_clock.game_time_minutes, current_posture, current_roe)

	_update_info_label()
	queue_redraw()


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


func _hex_to_pixel(col: int, row: int) -> Vector2:
	var x := col * hex_width * 0.75
	var y := row * hex_height
	if col % 2 == 1:
		y += hex_height * 0.5
	return Vector2(x, y)


func _pixel_to_hex(pixel: Vector2) -> Vector2i:
	var approx_col := pixel.x / (hex_width * 0.75)
	var col := int(round(approx_col))
	var y_offset := 0.0
	if col % 2 == 1:
		y_offset = hex_height * 0.5
	var approx_row := (pixel.y - y_offset) / hex_height
	var row := int(round(approx_row))

	var best := Vector2i(col, row)
	var best_dist := pixel.distance_to(_hex_to_pixel(col, row))
	for dc in range(-1, 2):
		for dr in range(-1, 2):
			var c := col + dc
			var r := row + dr
			if c < 0 or r < 0:
				continue
			var dist := pixel.distance_to(_hex_to_pixel(c, r))
			if dist < best_dist:
				best_dist = dist
				best = Vector2i(c, r)
	return best


func _is_valid_hex(coord: Vector2i) -> bool:
	return coord.x >= 0 and coord.x < map_cols and coord.y >= 0 and coord.y < map_rows
