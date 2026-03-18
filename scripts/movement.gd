class_name Movement
extends RefCounted

signal unit_moved(unit_name: String)

# External references
var hex_grid: HexGrid
var units: Array
var unit_types: Dictionary
var terrain_grid: Array
var terrain_types: Dictionary
var posture_configs: Dictionary
var order_manager: OrderManager
var game_clock: GameClock

# Set post-construction by hex_map
var combat: Combat = null  # for suppression checks
var death_markers: Dictionary = {}  # for wreck blocking


func _init(p_hex_grid: HexGrid, p_units: Array, p_unit_types: Dictionary,
		p_terrain_grid: Array, p_terrain_types: Dictionary,
		p_posture_configs: Dictionary, p_order_manager: OrderManager,
		p_game_clock: GameClock) -> void:
	hex_grid = p_hex_grid
	units = p_units
	unit_types = p_unit_types
	terrain_grid = p_terrain_grid
	terrain_types = p_terrain_types
	posture_configs = p_posture_configs
	order_manager = p_order_manager
	game_clock = p_game_clock


func move_units(minutes: float) -> void:
	for unit in units:
		var uname: String = unit["name"]
		var order: Order = order_manager.get_order(uname)
		if order == null or order.status != Order.Status.EXECUTING:
			continue

		# Immobilised units cannot move but can still fire
		if float(unit.get("mobility_damage", 0.0)) >= 1.0:
			continue

		var utype_code: String = unit["type_code"]
		var utype: Dictionary = unit_types.get(utype_code, {})
		var speed_kmh: float = float(utype.get("speed_kmh", 40))

		# Apply posture speed modifier
		var posture_str: String = Order.posture_to_string(order.posture)
		var posture_cfg: Dictionary = posture_configs.get(posture_str, {})
		var posture_speed_mod: float = posture_cfg.get("speed_modifier", 1.0)

		# Get terrain speed modifier for current hex (different for vehicles vs infantry)
		var cur_terrain: String = terrain_grid[unit["row"]][unit["col"]]
		var is_infantry: bool = unit.get("type_code", "") == "INF" or int(utype.get("speed_kmh", 50)) <= 10
		var terrain_speed_mod: float = 1.0
		if cur_terrain in terrain_types:
			var t_info: Dictionary = terrain_types[cur_terrain]
			if is_infantry:
				terrain_speed_mod = float(t_info.get("infantry_speed", t_info.get("speed_modifier", 1.0)))
			else:
				terrain_speed_mod = float(t_info.get("vehicle_speed", t_info.get("speed_modifier", 1.0)))

		if terrain_speed_mod <= 0.0 and not is_infantry:
			continue  # impassable for vehicles (infantry can ford rivers slowly)

		# Effective speed in km/h (degraded by mobility damage)
		var effective_speed: float = speed_kmh * posture_speed_mod * terrain_speed_mod
		var mob_dmg: float = float(unit.get("mobility_damage", 0.0))
		effective_speed *= clampf(1.0 - mob_dmg, 0.0, 1.0)
		# Distance covered this tick in km
		var distance_km: float = effective_speed * (minutes / 60.0)
		# Each hex is 0.5 km
		var hexes_moved: float = distance_km / 0.5

		# Accumulate fractional movement
		if not "move_accumulator" in unit:
			unit["move_accumulator"] = 0.0
		unit["move_accumulator"] = float(unit["move_accumulator"]) + hexes_moved

		# Step toward current waypoint one hex at a time
		while float(unit["move_accumulator"]) >= 1.0:
			var current: Vector2i = Vector2i(unit["col"], unit["row"])
			var target: Vector2i = order.current_target()

			if target == Vector2i(-1, -1):
				order.status = Order.Status.COMPLETE
				unit["move_accumulator"] = 0.0
				break

			if current == target:
				# Reached current waypoint - advance to next
				if not order.advance_waypoint():
					# PATROL: loop back to first waypoint
					if order.type == Order.Type.PATROL:
						order.current_waypoint_index = 0
						posture_str = Order.posture_to_string(order.posture)
						posture_cfg = posture_configs.get(posture_str, {})
						posture_speed_mod = posture_cfg.get("speed_modifier", 1.0)
						unit["move_accumulator"] = 0.0
						break
					# ATTACK/AMBUSH: persist at position
					if order.type == Order.Type.ATTACK:
						unit["move_accumulator"] = 0.0
						break
					if order.type == Order.Type.AMBUSH:
						order.ambush_set = true
						unit["move_accumulator"] = 0.0
						break
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
			var unit_morale: int = int(utype.get("morale", 50))
			var next_hex: Vector2i = next_step_toward(current, target, posture_str, unit_training, unit_morale)

			# Hesitation: low morale/poorly trained units in cover may stall
			# before moving into open ground
			var cur_terrain_code: String = terrain_grid[current.y][current.x]
			var next_terrain: String = terrain_grid[next_hex.y][next_hex.x]
			var in_cover: bool = cur_terrain_code == "W" or cur_terrain_code == "T"
			var leaving_cover: bool = in_cover and (next_terrain == "O" or next_terrain == "S")
			if leaving_cover and posture_str == "cautious":
				if not "hesitate_until" in unit:
					# Roll for hesitation based on training/morale
					var hesitate_chance: float = 0.0
					match unit_training:
						"militia": hesitate_chance = 0.6
						"irregular": hesitate_chance = 0.4
						"regular": hesitate_chance = 0.1
					hesitate_chance *= clampf((60.0 - unit_morale) / 50.0, 0.0, 1.0)
					if randf() < hesitate_chance:
						# Stall for 15-60 minutes
						var stall_minutes: float = randf_range(15.0, 60.0)
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

			# Check hex capacity (2 vehicles + 4 infantry max, no enemies)
			var unit_side: String = unit.get("side", "player")
			var unit_is_infantry: bool = unit.get("type_code", "") == "INF"
			var has_enemy: bool = false
			var friendly_vehicles: int = 0
			var friendly_infantry: int = 0
			for other in units:
				if other == unit:
					continue
				if other.get("unit_status", "") == "DESTROYED":
					continue
				if int(other["col"]) != next_hex.x or int(other["row"]) != next_hex.y:
					continue
				if other.get("side", "player") != unit_side:
					has_enemy = true
					break
				if other.get("type_code", "") == "INF":
					friendly_infantry += 1
				else:
					friendly_vehicles += 1
			if has_enemy:
				unit["move_accumulator"] = 0.0
				break
			var at_capacity: bool = false
			if unit_is_infantry and friendly_infantry >= 4:
				at_capacity = true
			elif not unit_is_infantry and friendly_vehicles >= 2:
				at_capacity = true
			if at_capacity:
				# Can't stop here - if this is destination, stop short
				if next_hex == target:
					unit["move_accumulator"] = 0.0
					break
				# If just passing through but out of movement, stop short
				if float(unit.get("move_accumulator", 0.0)) < 2.0:
					unit["move_accumulator"] = 0.0
					break

			# Check for road blocking: wrecks and heavily suppressed vehicles
			if not unit_is_infantry:
				var road_blocked: bool = false
				# Wreck blocking: death marker on this hex blocks vehicles
				if next_hex in death_markers:
					road_blocked = true
				# Heavily suppressed vehicle blocking: can't drive through a vehicle under heavy fire
				for other in units:
					if other == unit:
						continue
					if other.get("unit_status", "") == "DESTROYED":
						continue
					if int(other["col"]) != next_hex.x or int(other["row"]) != next_hex.y:
						continue
					if combat != null:
						var other_supp: float = combat.get_suppression(other.get("name", ""))
						if other_supp > 40 and other.get("type_code", "") != "INF":
							road_blocked = true
							break
				if road_blocked:
					unit["move_accumulator"] = 0.0
					break

			unit["col"] = next_hex.x
			unit["row"] = next_hex.y
			unit["move_accumulator"] = float(unit["move_accumulator"]) - 1.0

			# Notify that unit changed hex so hex_map can update LOS
			unit_moved.emit(uname)


func next_step_toward(from: Vector2i, to: Vector2i, posture_name: String = "normal",
		_training: String = "regular", _morale: int = 50) -> Vector2i:
	var neighbors: Array[Vector2i] = hex_grid.get_hex_neighbors(from)
	var best: Vector2i = from
	var best_score: float = 999999.0
	var pcfg: Dictionary = posture_configs.get(posture_name, {})
	var road_pref: float = pcfg.get("road_preference", 1.0)
	var cover_pref: float = pcfg.get("cover_preference", 0.5)

	var cur_dist: float = float(hex_grid.hex_distance(from, to))
	var found_progress: bool = false

	# First pass: try neighbors that make progress or go sideways
	for n in neighbors:
		if n.x < 0 or n.x >= hex_grid.map_cols or n.y < 0 or n.y >= hex_grid.map_rows:
			continue
		var dist: float = float(hex_grid.hex_distance(n, to))
		if dist > cur_dist:
			continue

		var n_terrain: String = terrain_grid[n.y][n.x]
		var t_info: Dictionary = terrain_types.get(n_terrain, {})
		var speed_mod: float = float(t_info.get("speed_modifier", 1.0))
		if speed_mod <= 0.0:
			continue

		found_progress = true
		var cost: float = dist * 10.0
		if n_terrain == "S":
			cost -= road_pref * 0.4
		if n_terrain == "W" or n_terrain == "T":
			cost -= cover_pref * 0.4
		if n_terrain == "O":
			cost += cover_pref * 0.2

		if cost < best_score:
			best_score = cost
			best = n

	# Second pass: if stuck, allow one step backward to get unstuck
	if not found_progress:
		for n in neighbors:
			if n.x < 0 or n.x >= hex_grid.map_cols or n.y < 0 or n.y >= hex_grid.map_rows:
				continue
			var n_terrain: String = terrain_grid[n.y][n.x]
			var t_info: Dictionary = terrain_types.get(n_terrain, {})
			var speed_mod: float = float(t_info.get("speed_modifier", 1.0))
			if speed_mod <= 0.0:
				continue
			var dist: float = float(hex_grid.hex_distance(n, to))
			var cost: float = dist * 10.0
			if cost < best_score:
				best_score = cost
				best = n

	return best
