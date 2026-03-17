class_name HQComms
extends RefCounted

# External references
var hex_grid: HexGrid
var units: Array
var unit_types: Dictionary
var elevation_grid: Array
var combat: Combat
var order_manager: OrderManager
var game_clock: GameClock

# HQ config values (set post-construction)
var hq_switching_cost: float = 15.0
var hq_comms_order_buff: float = 0.8
var hq_los_order_buff: float = 0.6
var hq_los_morale_buff: int = 5
var hq_los_accuracy_buff: float = 1.1
var hq_los_suppression_resistance: float = 0.85
var hq_auto_switch_minutes: float = 10.0

# OODA config values (set post-construction)
var ooda_base_cycle: float = 15.0
var ooda_min_cycle: float = 5.0
var ooda_max_cycle: float = 45.0
var ooda_training_modifiers: Dictionary = {}
var ooda_hq_moving_penalty: float = 1.5
var ooda_hq_suppressed_penalty: float = 2.0
var ooda_hq_destroyed_penalty: float = 3.0
var ooda_hq_crew_loss_per: float = 0.25
var ooda_direct_to_top_penalty: float = 1.3

# Night config (set post-construction)
var sunrise_hour: int = 6
var sunset_hour: int = 19
var night_ooda_penalty: float = 1.5

# Spotting range delegate - set by hex_map to combat_resolver.get_effective_spotting_range
var get_effective_spotting_range: Callable


func _init(p_hex_grid: HexGrid, p_units: Array, p_unit_types: Dictionary,
		p_elevation_grid: Array, p_combat: Combat, p_order_manager: OrderManager,
		p_game_clock: GameClock) -> void:
	hex_grid = p_hex_grid
	units = p_units
	unit_types = p_unit_types
	elevation_grid = p_elevation_grid
	combat = p_combat
	order_manager = p_order_manager
	game_clock = p_game_clock


func _is_night() -> bool:
	var hour: int = (int(game_clock.game_time_minutes) / 60) % 24
	return hour < sunrise_hour or hour >= sunset_hour


func update_hq_comms(minutes: float) -> void:
	for unit in units:
		if unit.get("unit_status", "") == "DESTROYED":
			continue
		var switch_remaining: float = float(unit.get("hq_switch_remaining", 0.0))
		if switch_remaining > 0:
			unit["hq_switch_remaining"] = maxf(0.0, switch_remaining - minutes)
			unit["in_comms"] = false
			unit["in_hq_los"] = false
			continue
		var assigned_hq_name: String = unit.get("assigned_hq", "")
		if assigned_hq_name == "":
			unit["in_comms"] = false
			unit["in_hq_los"] = false
			continue
		# Find the assigned HQ unit
		var hq_unit: Dictionary = {}
		for other in units:
			if other.get("name", "") == assigned_hq_name:
				hq_unit = other
				break
		if hq_unit.is_empty() or hq_unit.get("unit_status", "") == "DESTROYED":
			unit["in_comms"] = false
			unit["in_hq_los"] = false
			continue
		# Get HQ unit type's comms range
		var hq_type_code: String = hq_unit.get("type_code", "")
		var hq_utype: Dictionary = unit_types.get(hq_type_code, {})
		var comms_data: Dictionary = hq_utype.get("comms", {})
		var comms_range_km: float = float(comms_data.get("range_km", 0))
		var comms_range_hexes: float = comms_range_km / 0.5
		# Calculate hex distance
		var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
		var hq_pos: Vector2i = Vector2i(hq_unit["col"], hq_unit["row"])
		var distance: int = hex_grid.hex_distance(unit_pos, hq_pos)
		unit["in_comms"] = float(distance) <= comms_range_hexes

		# If out of comms, try to find another friendly HQ in range
		if not unit.get("in_comms", false):
			var best_hq_name: String = ""
			var best_hq_dist: int = 9999
			var unit_side: String = unit.get("side", "player")
			for other in units:
				if other.get("side", "player") != unit_side:
					continue
				if other == unit:
					continue
				if other.get("unit_status", "") == "DESTROYED":
					continue
				var other_utype: Dictionary = unit_types.get(other.get("type_code", ""), {})
				if not other_utype.get("is_hq", false):
					continue
				if other.get("name", "") == assigned_hq_name:
					continue  # already checked this one
				var other_comms = other_utype.get("comms", {})
				if not (other_comms is Dictionary) or other_comms.is_empty():
					continue
				var other_range: float = float(other_comms.get("range_km", 0)) / 0.5
				var other_pos: Vector2i = Vector2i(other["col"], other["row"])
				var other_dist: int = hex_grid.hex_distance(unit_pos, other_pos)
				if float(other_dist) <= other_range and other_dist < best_hq_dist:
					best_hq_dist = other_dist
					best_hq_name = other.get("name", "")
			if best_hq_name != "":
				unit["assigned_hq"] = best_hq_name
				unit["hq_switch_remaining"] = hq_auto_switch_minutes
				unit["in_comms"] = false
				unit["in_hq_los"] = false
				combat.log_event("%s switching to %s (10 min)" % [
					unit.get("name", "?"), best_hq_name])
				continue

		# LOS check is independent of comms - within spotting range and can see HQ
		var unit_spot: int = get_effective_spotting_range.call(unit)
		var unit_elev: int = elevation_grid[unit_pos.y][unit_pos.x]
		unit["in_hq_los"] = distance <= unit_spot and hex_grid.has_los(unit_pos, unit_elev, hq_pos)


func get_hq_order_modifier(unit: Dictionary) -> float:
	if unit.get("in_hq_los", false):
		return hq_los_order_buff
	if unit.get("in_comms", false):
		return hq_comms_order_buff
	return 1.0


func calculate_ooda_cycle() -> Array:
	## Calculate the current OODA cycle length based on top-level HQ status.
	## Returns [cycle_float, breakdown_array] so the caller can update UI.
	var cycle: float = ooda_base_cycle
	var breakdown: Array[String] = ["Base: %.0f min" % ooda_base_cycle]

	# Find the top-level HQ
	var top_hq: Dictionary = {}
	for unit in units:
		if unit.get("side", "player") != "player":
			continue
		var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
		if utype.get("is_hq", false) and int(utype.get("hq_level", 0)) == 1:
			top_hq = unit
			break

	if top_hq.is_empty() or top_hq.get("unit_status", "") == "DESTROYED":
		cycle *= ooda_hq_destroyed_penalty
		breakdown.append("HQ destroyed: x%.1f" % ooda_hq_destroyed_penalty)
		var result: float = clampf(cycle, ooda_min_cycle, ooda_max_cycle)
		return [result, breakdown]

	# Training modifier from HQ unit type
	var hq_utype: Dictionary = unit_types.get(top_hq.get("type_code", ""), {})
	var training: String = str(hq_utype.get("training", "regular"))
	var train_mod: float = ooda_training_modifiers.get(training, 1.0)
	cycle *= train_mod
	if train_mod != 1.0:
		breakdown.append("HQ training (%s): x%.1f" % [training, train_mod])

	# HQ moving penalty
	var hq_order: Order = order_manager.get_order(top_hq.get("name", ""))
	if hq_order != null and hq_order.status == Order.Status.EXECUTING:
		cycle *= ooda_hq_moving_penalty
		breakdown.append("HQ moving: x%.1f" % ooda_hq_moving_penalty)

	# HQ suppressed penalty
	var hq_supp: float = combat.get_suppression(top_hq.get("name", ""))
	if hq_supp > 10:
		cycle *= ooda_hq_suppressed_penalty
		breakdown.append("HQ under fire: x%.1f" % ooda_hq_suppressed_penalty)

	# HQ crew casualties
	var max_crew: int = int(hq_utype.get("crew", 3))
	var cur_crew: int = int(top_hq.get("current_crew", max_crew))
	var crew_lost: int = max_crew - cur_crew
	if crew_lost > 0:
		var crew_mult: float = 1.0 + float(crew_lost) * ooda_hq_crew_loss_per
		cycle *= crew_mult
		breakdown.append("HQ casualties (%d lost): x%.1f" % [crew_lost, crew_mult])

	# Check if any combat units are directly under top-level HQ (bypassing company layer)
	var top_hq_name: String = top_hq.get("name", "")
	var has_direct_reports: bool = false
	for u in units:
		if u.get("side", "player") != "player":
			continue
		if u.get("unit_status", "") == "DESTROYED":
			continue
		var u_utype: Dictionary = unit_types.get(u.get("type_code", ""), {})
		if u_utype.get("is_hq", false):
			continue
		if u.get("assigned_hq", "") == top_hq_name:
			has_direct_reports = true
			break
	if has_direct_reports:
		cycle *= ooda_direct_to_top_penalty
		breakdown.append("Units under direct BHQ command: x%.1f" % ooda_direct_to_top_penalty)

	# Night penalty
	if _is_night():
		cycle *= night_ooda_penalty
		breakdown.append("Night: x%.1f" % night_ooda_penalty)

	var result: float = clampf(cycle, ooda_min_cycle, ooda_max_cycle)
	breakdown.append("---")
	breakdown.append("Total: %.0f min" % result)
	return [result, breakdown]
