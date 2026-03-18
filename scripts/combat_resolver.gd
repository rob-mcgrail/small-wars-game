class_name CombatResolver
extends RefCounted

## Extracted from hex_map.gd: handles combat resolution, morale, destruction, and pursuit.

# External references (set in _init)
var hex_grid: HexGrid
var units: Array
var unit_types: Dictionary
var terrain_grid: Array
var elevation_grid: Array
var terrain_types: Dictionary
var combat: Combat
var order_manager: OrderManager
var game_clock: GameClock

# Night config (set by hex_map after construction)
# Player defaults
var night_accuracy_modifier: float = 0.4
var night_range_modifier: float = 0.5
var night_spotting_modifier: float = 0.3
# Enemy-specific (default to same as player, overridden by scenario)
var enemy_night_accuracy_modifier: float = 0.4
var enemy_night_range_modifier: float = 0.5
var enemy_night_spotting_modifier: float = 0.3
var sunrise_hour: int = 6
var sunset_hour: int = 19

# HQ config
var hq_los_accuracy_buff: float = 1.1
var hq_los_suppression_resistance: float = 0.85
var hq_los_morale_buff: int = 5

# Destruction config
var destruction_marker_duration: float = 60.0
var destruction_direct_hq_shock: int = 15
var destruction_parent_hq_shock: int = 8
var destruction_los_witness_shock: int = 10

# Morale thresholds
var MORALE_BREAK_THRESHOLD: int = 30
var MORALE_ROUT_THRESHOLD: int = 15

# ROE rate constants
var ROE_RATE_FIRE_AT_WILL: float = 0.035
var ROE_RATE_RETURN_FIRE: float = 0.015
var ROE_RATE_HALT_AND_ENGAGE: float = 0.05

# Posture configs
var posture_configs: Dictionary = {}

# Shared mutable state references (set by hex_map after construction)
var fire_effects: Array = []
var death_markers: Dictionary = {}

# Map dimensions (needed for spotting range calculation)
var map_cols: int = 0
var map_rows: int = 0


func _init(p_hex_grid: HexGrid, p_units: Array, p_unit_types: Dictionary,
		p_terrain_grid: Array, p_elevation_grid: Array, p_terrain_types: Dictionary,
		p_combat: Combat, p_order_manager: OrderManager, p_game_clock: GameClock) -> void:
	hex_grid = p_hex_grid
	units = p_units
	unit_types = p_unit_types
	terrain_grid = p_terrain_grid
	elevation_grid = p_elevation_grid
	terrain_types = p_terrain_types
	combat = p_combat
	order_manager = p_order_manager
	game_clock = p_game_clock


# ---------------------------------------------------------------------------
# Night / HQ helpers (private)
# ---------------------------------------------------------------------------

func _is_night() -> bool:
	var hour: int = (int(game_clock.game_time_minutes) / 60) % 24
	return hour < sunrise_hour or hour >= sunset_hour


func _unit_has_night_vision(unit: Dictionary) -> bool:
	var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
	if utype.get("night_vision", false):
		return true
	# Check optics for night_vision flag
	var optics = utype.get("optics", {})
	if optics is Dictionary:
		return optics.get("night_vision", false)
	return false


func _get_hq_accuracy_modifier(unit: Dictionary) -> float:
	if unit.get("in_hq_los", false):
		return hq_los_accuracy_buff
	return 1.0


func _get_hq_suppression_modifier(unit: Dictionary) -> float:
	if unit.get("in_hq_los", false):
		return hq_los_suppression_resistance
	return 1.0


# ---------------------------------------------------------------------------
# Combat functions
# ---------------------------------------------------------------------------

func resolve_unit_combat(unit: Dictionary, minutes: float) -> void:
	var uname: String = unit.get("name", "")
	if unit.get("unit_status", "") == "DESTROYED":
		return

	var order: Order = order_manager.get_order(uname)

	# Ambush logic: override normal ROE when ambush is set
	if order != null and order.type == Order.Type.AMBUSH and order.ambush_set:
		_handle_ambush(unit, order, minutes)
		return

	var roe: Order.ROE = get_effective_roe(unit, order)

	if roe == Order.ROE.HOLD_FIRE:
		return

	var targets: Array = find_targets_in_range(unit)
	if targets.is_empty():
		return

	# Halt & Engage only fires when stopped
	if roe == Order.ROE.HALT_AND_ENGAGE:
		if order != null and order.status == Order.Status.EXECUTING:
			return

	# Return Fire needs someone shooting at us
	if roe == Order.ROE.RETURN_FIRE:
		var being_engaged: bool = false
		for target in targets:
			var t_order: Order = order_manager.get_order(target.get("name", ""))
			var t_roe: Order.ROE = get_effective_roe(target, t_order)
			if t_roe == Order.ROE.FIRE_AT_WILL or t_roe == Order.ROE.HALT_AND_ENGAGE:
				being_engaged = true
				break
		if not being_engaged:
			return

	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var weapons: Array = utype.get("weapons", [])
	var ammo_arr: Array = unit.get("current_ammo", [])
	var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
	var is_moving: bool = order != null and order.status == Order.Status.EXECUTING

	# ROE multiplier on each weapon's rate_of_fire
	var roe_mult: float = 0.0
	match roe:
		Order.ROE.FIRE_AT_WILL:
			roe_mult = ROE_RATE_FIRE_AT_WILL
		Order.ROE.RETURN_FIRE:
			roe_mult = ROE_RATE_RETURN_FIRE
		Order.ROE.HALT_AND_ENGAGE:
			roe_mult = ROE_RATE_HALT_AND_ENGAGE

	# Crew casualties reduce fire rate
	var crew_ratio: float = 1.0
	var max_crew: int = int(utype.get("crew", 4))
	var cur_crew: int = int(unit.get("current_crew", max_crew))
	if max_crew > 0:
		crew_ratio = clampf(float(cur_crew) / float(max_crew), 0.0, 1.0)
	if cur_crew <= 0:
		return  # No crew left

	var fired_any: bool = false

	for wi in range(weapons.size()):
		if wi >= ammo_arr.size():
			continue
		var current_ammo: int = int(ammo_arr[wi])
		if current_ammo <= 0:
			continue

		var w: Dictionary = weapons[wi]
		var w_range_km: float = float(w.get("range_km", 0))
		var w_supp_range_km: float = float(w.get("suppressive_range_km", w_range_km))
		if is_moving:
			w_range_km = float(w.get("range_moving_km", w_range_km * 0.3))
			w_supp_range_km = w_range_km  # no suppressive bonus while moving
		# Night reduces effective engagement ranges
		if _is_night() and not _unit_has_night_vision(unit):
			w_range_km *= night_range_modifier
			w_supp_range_km *= night_range_modifier
		# Max engagement range is the suppressive range
		var w_max_range_hexes: float = w_supp_range_km / 0.5
		var w_effective_range_hexes: float = w_range_km / 0.5

		# Find closest valid target for this weapon (within suppressive range)
		var best_target: Dictionary = {}
		var best_dist: int = 999
		for target in targets:
			if target.get("unit_status", "") == "DESTROYED":
				continue
			var t_pos: Vector2i = Vector2i(target["col"], target["row"])
			var dist: int = hex_grid.hex_distance(unit_pos, t_pos)
			if float(dist) <= w_max_range_hexes and dist < best_dist:
				best_dist = dist
				best_target = target

		if best_target.is_empty():
			continue

		# Calculate rounds fired this tick
		var rof: float = float(w.get("rate_of_fire", 600))
		# Single-shot weapons (ATGMs, RPGs, cannons) fire at their stated rate
		# The ROE multiplier only applies to high-volume weapons (machine guns, rifles)
		var effective_roe_mult: float = roe_mult
		if rof <= 10:
			# Low-rate weapons: ROE barely affects fire rate
			# They fire when they have a target, period
			effective_roe_mult = maxf(roe_mult, 0.8)
		# Troops conserve ammo as it gets low
		var max_ammo: int = 0
		var w_weapons: Array = utype.get("weapons", [])
		if wi < w_weapons.size():
			max_ammo = int(w_weapons[wi].get("ammo", 0))
		var conservation: float = consume_ammo_conservation(current_ammo, max_ammo)
		var rounds_f: float = rof * effective_roe_mult * minutes * crew_ratio * conservation
		var rounds: int = int(rounds_f)
		# Stochastic rounding for fractional rounds
		if randf() < (rounds_f - float(rounds)):
			rounds += 1
		rounds = mini(rounds, current_ammo)
		if rounds <= 0:
			continue

		# Resolve each shot
		var target_pos: Vector2i = Vector2i(best_target["col"], best_target["row"])
		var target_terrain: String = terrain_grid[target_pos.y][target_pos.x]
		var target_type_code: String = best_target.get("type_code", "")
		var target_type: Dictionary = unit_types.get(target_type_code, {})
		var target_armor: int = int(target_type.get("armor", 0))
		var target_order: Order = order_manager.get_order(best_target.get("name", ""))
		var target_moving: bool = target_order != null and target_order.status == Order.Status.EXECUTING

		var is_suppressive: bool = float(best_dist) > w_effective_range_hexes
		var shooter_elev: int = elevation_grid[unit_pos.y][unit_pos.x]
		var target_elev_val: int = elevation_grid[target_pos.y][target_pos.x]
		var elev_diff: int = shooter_elev - target_elev_val
		var hq_acc: float = _get_hq_accuracy_modifier(unit)
		# Night penalty on accuracy
		var night_acc: float = 1.0
		if _is_night() and not _unit_has_night_vision(unit):
			night_acc = night_accuracy_modifier
		var total_acc: float = hq_acc * night_acc
		var result: Dictionary = combat.resolve_combat(
			unit, best_target, utype, target_type,
			wi, rounds, best_dist,
			is_moving, target_moving,
			target_terrain, target_armor, is_suppressive, elev_diff, total_acc)

		# Apply results
		ammo_arr[wi] = current_ammo - rounds
		fired_any = true

		if result["hits"] > 0 or result["suppression_added"] > 0:
			var t_name: String = best_target.get("name", "?")
			var supp_mod: float = _get_hq_suppression_modifier(best_target)
			combat.apply_suppression(t_name, result["suppression_added"] * supp_mod)

		if result["crew_killed"] > 0:
			var t_crew: int = int(best_target.get("current_crew", 4))
			best_target["current_crew"] = maxi(0, t_crew - result["crew_killed"])
			combat.log_event("%s hit %s: %d casualties" % [
				uname, best_target.get("name", "?"), result["crew_killed"]])

		if result["vehicle_damage"] > 0.0:
			var cur_dmg: float = float(best_target.get("vehicle_damage", 0.0))
			best_target["vehicle_damage"] = cur_dmg + result["vehicle_damage"]

		# Apply mobility damage
		var mob_result: float = float(result.get("mobility_damage", 0.0))
		if mob_result > 0.0:
			var cur_mob: float = float(best_target.get("mobility_damage", 0.0))
			best_target["mobility_damage"] = clampf(cur_mob + mob_result, 0.0, 1.5)
			if float(best_target["mobility_damage"]) >= 1.0 and best_target.get("unit_status", "") == "":
				best_target["unit_status"] = "IMMOBILISED"
				order_manager.cancel_order(best_target.get("name", ""))
				combat.log_event("%s is IMMOBILISED!" % best_target.get("name", "?"))

		# Apply weapon disabled
		if result.get("weapon_disabled", false):
			var t_ammo: Array = best_target.get("current_ammo", [])
			# Disable a random weapon that still has ammo
			var valid_indices: Array[int] = []
			for ai in range(t_ammo.size()):
				if int(t_ammo[ai]) > 0:
					valid_indices.append(ai)
			if not valid_indices.is_empty():
				var disable_idx: int = valid_indices[randi() % valid_indices.size()]
				t_ammo[disable_idx] = 0
				best_target["current_ammo"] = t_ammo
				var t_utype: Dictionary = unit_types.get(best_target.get("type_code", ""), {})
				var t_weapons: Array = t_utype.get("weapons", [])
				var disabled_name: String = "weapon"
				if disable_idx < t_weapons.size():
					disabled_name = str(t_weapons[disable_idx].get("name", "weapon"))
				combat.log_event("%s: %s DISABLED by %s" % [best_target.get("name", "?"), disabled_name, uname])

		# Check if target is destroyed or should abandon vehicle
		var t_crew_left: int = int(best_target.get("current_crew", 0))
		var t_dmg: float = float(best_target.get("vehicle_damage", 0.0))
		var t_mob_dmg: float = float(best_target.get("mobility_damage", 0.0))
		if t_crew_left <= 0 or t_dmg >= 1.0:
			if best_target.get("unit_status", "") != "DESTROYED":
				best_target["unit_status"] = "DESTROYED"
				order_manager.cancel_order(best_target.get("name", ""))
				combat.log_event("%s DESTROYED by %s" % [best_target.get("name", "?"), uname])
				on_unit_destroyed(best_target)
		elif t_crew_left > 0:
			# Vehicle abandonment - thresholds are lower when broken/routing
			var t_status: String = best_target.get("unit_status", "")
			var abandon_vdmg: float = 0.7
			var abandon_mob: float = 0.8
			if t_status == "ROUTING":
				abandon_vdmg = 0.35
				abandon_mob = 0.4
			elif t_status == "BROKEN":
				abandon_vdmg = 0.5
				abandon_mob = 0.6
			if (t_dmg >= abandon_vdmg or t_mob_dmg >= abandon_mob) and t_status != "DESTROYED":
				abandon_vehicle(best_target)

		if rounds > 0:
			# Create fire effect visual
			fire_effects.append({
				"from": Vector2i(unit["col"], unit["row"]),
				"to": target_pos,
				"time_remaining": 2.0,
				"hit": result["hits"] > 0,
			})
		if result["hits"] > 0:
			var w_name: String = w.get("name", "?")
			combat.log_event("%s fires %s: %d rounds, %d hits on %s" % [
				uname, w_name, rounds, result["hits"], best_target.get("name", "?")])

	unit["current_ammo"] = ammo_arr
	if fired_any:
		check_morale(unit)


func _handle_ambush(unit: Dictionary, order: Order, minutes: float) -> void:
	var targets: Array = find_targets_in_range(unit)
	if targets.is_empty():
		return  # No targets, keep waiting

	var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
	var unit_pos := Vector2i(unit["col"], unit["row"])

	# Find best weapon effective range in hexes
	var weapons = utype.get("weapons", [])
	if not (weapons is Array):
		return
	var best_effective_range: float = 0.0
	for w in weapons:
		var r: float = float(w.get("range_km", 0))
		if r > best_effective_range:
			best_effective_range = r
	var effective_hexes: int = int(best_effective_range / 0.5)

	if not order.ambush_triggered:
		# Score the engagement - wait for optimal moment
		var trigger_score: float = 0.0
		var closest_enemy: int = 999
		for target in targets:
			if target.get("unit_status", "") == "DESTROYED":
				continue
			var t_pos := Vector2i(target["col"], target["row"])
			var dist: int = hex_grid.hex_distance(unit_pos, t_pos)
			if dist < closest_enemy:
				closest_enemy = dist
			# Higher score for enemies in effective range (not just spotting range)
			if dist <= effective_hexes:
				trigger_score += 3.0 - float(dist) * 0.5  # closer = better
			else:
				trigger_score += 0.5  # in spotting range but not effective

		# Trigger conditions:
		# - Any enemy within 1 hex (they'll spot us for sure)
		# - Score >= 3.0 (at least one enemy at good range)
		if closest_enemy <= 1 or trigger_score >= 3.0:
			order.ambush_triggered = true
			order.ambush_trigger_time = game_clock.game_time_minutes
			combat.log_event("%s AMBUSH triggered!" % unit.get("name", "?"))
		else:
			return  # Not yet, keep waiting

	# Ambush has triggered - fight with bonuses
	# Terrain-based ambush quality multiplier
	var terrain_code: String = terrain_grid[unit_pos.y][unit_pos.x]
	var ambush_concealment_bonus: float = 1.0
	var ambush_accuracy_bonus: float = 1.0
	match terrain_code:
		"W":  # Woods - excellent ambush terrain
			ambush_concealment_bonus = 2.0
			ambush_accuracy_bonus = 1.8
		"T":  # Town - good ambush terrain
			ambush_concealment_bonus = 1.8
			ambush_accuracy_bonus = 1.6
		"C":  # City - good ambush terrain
			ambush_concealment_bonus = 1.8
			ambush_accuracy_bonus = 1.6
		"O":  # Open - poor ambush, slight bonus from being dug in
			ambush_concealment_bonus = 1.2
			ambush_accuracy_bonus = 1.2
		"S":  # Street - minimal ambush
			ambush_concealment_bonus = 1.1
			ambush_accuracy_bonus = 1.1

	# First volley bonus decays over 3 minutes after trigger
	var time_since_trigger: float = game_clock.game_time_minutes - order.ambush_trigger_time
	var first_volley_bonus: float = 1.0
	if time_since_trigger < 3.0:
		# Surprise multiplier: 2.5x at trigger, fading to 1.0 over 3 minutes
		first_volley_bonus = lerpf(2.5, 1.0, clampf(time_since_trigger / 3.0, 0.0, 1.0))

	var total_accuracy_mod: float = ambush_accuracy_bonus * first_volley_bonus

	# Override ROE to fire at will during ambush
	# Use the normal combat resolution but with boosted accuracy
	var utype_code: String = unit.get("type_code", "")
	var ammo_arr: Array = unit.get("current_ammo", [])
	var is_moving: bool = false
	var crew_ratio: float = 1.0
	var max_crew: int = int(utype.get("crew", 4))
	var cur_crew: int = int(unit.get("current_crew", max_crew))
	if max_crew > 0:
		crew_ratio = clampf(float(cur_crew) / float(max_crew), 0.0, 1.0)
	if cur_crew <= 0:
		return

	var roe_mult: float = ROE_RATE_FIRE_AT_WILL
	var fired_any: bool = false

	for wi in range(weapons.size()):
		if wi >= ammo_arr.size():
			continue
		var current_ammo: int = int(ammo_arr[wi])
		if current_ammo <= 0:
			continue

		var w: Dictionary = weapons[wi]
		var w_range_km: float = float(w.get("range_km", 0))
		var w_supp_range_km: float = float(w.get("suppressive_range_km", w_range_km))
		if _is_night() and not _unit_has_night_vision(unit):
			w_range_km *= night_range_modifier
			w_supp_range_km *= night_range_modifier
		var w_max_range_hexes: float = w_supp_range_km / 0.5
		var w_effective_range_hexes: float = w_range_km / 0.5

		var best_target: Dictionary = {}
		var best_dist: int = 999
		for target in targets:
			if target.get("unit_status", "") == "DESTROYED":
				continue
			var t_pos := Vector2i(target["col"], target["row"])
			var dist: int = hex_grid.hex_distance(unit_pos, t_pos)
			if float(dist) <= w_max_range_hexes and dist < best_dist:
				best_dist = dist
				best_target = target

		if best_target.is_empty():
			continue

		var rof: float = float(w.get("rate_of_fire", 600))
		var effective_roe_mult: float = roe_mult
		if rof <= 10:
			effective_roe_mult = maxf(roe_mult, 0.8)
		var max_ammo: int = int(w.get("ammo", 0))
		var ammo_pct: float = float(current_ammo) / maxf(1.0, float(max_ammo))
		var conservation: float = 1.0
		if ammo_pct < 0.5:
			conservation = clampf(ammo_pct / 0.5, 0.2, 1.0)
		var rounds_f: float = rof * effective_roe_mult * minutes * crew_ratio * conservation
		var rounds: int = int(rounds_f)
		if randf() < (rounds_f - float(rounds)):
			rounds += 1
		rounds = mini(rounds, current_ammo)
		if rounds <= 0:
			continue

		var target_pos := Vector2i(best_target["col"], best_target["row"])
		var target_terrain: String = terrain_grid[target_pos.y][target_pos.x]
		var target_type_code: String = best_target.get("type_code", "")
		var target_type: Dictionary = unit_types.get(target_type_code, {})
		var target_armor: int = int(target_type.get("armor", 0))
		var target_order: Order = order_manager.get_order(best_target.get("name", ""))
		var target_moving: bool = target_order != null and target_order.status == Order.Status.EXECUTING

		var is_suppressive: bool = float(best_dist) > w_effective_range_hexes
		var shooter_elev: int = elevation_grid[unit_pos.y][unit_pos.x]
		var target_elev_val: int = elevation_grid[target_pos.y][target_pos.x]
		var elev_diff: int = shooter_elev - target_elev_val

		var result: Dictionary = combat.resolve_combat(
			unit, best_target, utype, target_type,
			wi, rounds, best_dist,
			is_moving, target_moving,
			target_terrain, target_armor, is_suppressive, elev_diff,
			total_accuracy_mod)

		ammo_arr[wi] = current_ammo - rounds
		fired_any = true

		if result["hits"] > 0 or result["suppression_added"] > 0:
			var t_name: String = best_target.get("name", "?")
			var supp_mod: float = _get_hq_suppression_modifier(best_target)
			combat.apply_suppression(t_name, result["suppression_added"] * supp_mod)

		if result["crew_killed"] > 0:
			var t_crew: int = int(best_target.get("current_crew", 4))
			best_target["current_crew"] = maxi(0, t_crew - result["crew_killed"])

		if result["vehicle_damage"] > 0.0:
			var cur_dmg: float = float(best_target.get("vehicle_damage", 0.0))
			best_target["vehicle_damage"] = cur_dmg + result["vehicle_damage"]

		var mob_result: float = float(result.get("mobility_damage", 0.0))
		if mob_result > 0.0:
			var cur_mob: float = float(best_target.get("mobility_damage", 0.0))
			best_target["mobility_damage"] = clampf(cur_mob + mob_result, 0.0, 1.5)

		if result.get("weapon_disabled", false):
			var t_ammo: Array = best_target.get("current_ammo", [])
			var valid_indices: Array[int] = []
			for ai in range(t_ammo.size()):
				if int(t_ammo[ai]) > 0:
					valid_indices.append(ai)
			if not valid_indices.is_empty():
				var disable_idx: int = valid_indices[randi() % valid_indices.size()]
				t_ammo[disable_idx] = 0
				best_target["current_ammo"] = t_ammo

		# Check destruction/abandonment
		var t_crew_left: int = int(best_target.get("current_crew", 0))
		var t_dmg: float = float(best_target.get("vehicle_damage", 0.0))
		var t_mob_dmg: float = float(best_target.get("mobility_damage", 0.0))
		if t_crew_left <= 0 or t_dmg >= 1.0:
			if best_target.get("unit_status", "") != "DESTROYED":
				best_target["unit_status"] = "DESTROYED"
				order_manager.cancel_order(best_target.get("name", ""))
				combat.log_event("%s DESTROYED by %s (AMBUSH)" % [best_target.get("name", "?"), unit.get("name", "?")])
				on_unit_destroyed(best_target)
		elif t_crew_left > 0:
			var t_status: String = best_target.get("unit_status", "")
			var abandon_vdmg: float = 0.7
			var abandon_mob: float = 0.8
			if t_status == "ROUTING":
				abandon_vdmg = 0.35
				abandon_mob = 0.4
			elif t_status == "BROKEN":
				abandon_vdmg = 0.5
				abandon_mob = 0.6
			if (t_dmg >= abandon_vdmg or t_mob_dmg >= abandon_mob) and t_status != "DESTROYED":
				abandon_vehicle(best_target)

		if rounds > 0:
			fire_effects.append({
				"from": Vector2i(unit["col"], unit["row"]),
				"to": target_pos,
				"time_remaining": 2.0,
				"hit": result["hits"] > 0,
			})
		if result["hits"] > 0:
			var w_name: String = w.get("name", "?")
			combat.log_event("%s AMBUSH fires %s: %d rounds, %d hits on %s" % [
				unit.get("name", "?"), w_name, rounds, result["hits"], best_target.get("name", "?")])

	unit["current_ammo"] = ammo_arr
	if fired_any:
		check_morale(unit)


func find_targets_in_range(unit: Dictionary) -> Array:
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
	var unit_side: String = unit.get("side", "player")
	var spot_range: int = get_effective_spotting_range(unit)
	var unit_elev: int = elevation_grid[unit_pos.y][unit_pos.x]

	var targets: Array = []
	for other in units:
		if other.get("side", "player") == unit_side:
			continue
		var other_pos: Vector2i = Vector2i(other["col"], other["row"])
		if hex_grid.hex_distance(unit_pos, other_pos) > spot_range:
			continue
		if hex_grid.has_los(unit_pos, unit_elev, other_pos):
			targets.append(other)
	return targets


func get_effective_roe(unit: Dictionary, order: Order) -> Order.ROE:
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
		# Units without orders default to return fire
		# Check for a standing ROE on the unit dict
		var default_roe: String = unit.get("default_roe", "return fire")
		return Order.roe_from_string(default_roe)
	return order.roe


func get_effective_spotting_range(unit: Dictionary) -> int:
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	# Derive base range from optics (range_km / 0.5km per hex)
	var optics = utype.get("optics", {})
	var base_range: int = 4  # default fallback
	if optics is Dictionary and not optics.is_empty():
		base_range = int(float(optics.get("range_km", 2.0)) / 0.5)
	var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
	var unit_elev: int = elevation_grid[unit_pos.y][unit_pos.x]
	# +1 hex spotting per elevation level above the lowest terrain at the edge of base range
	var min_elev_at_edge: int = unit_elev
	for dc in range(-base_range, base_range + 1):
		for dr in range(-base_range, base_range + 1):
			var c: int = unit_pos.x + dc
			var r: int = unit_pos.y + dr
			if c >= 0 and c < map_cols and r >= 0 and r < map_rows:
				var d: int = hex_grid.hex_distance(unit_pos, Vector2i(c, r))
				if d >= base_range - 1 and d <= base_range:
					var e: int = elevation_grid[r][c]
					if e < min_elev_at_edge:
						min_elev_at_edge = e
	var elev_bonus: int = maxi(0, unit_elev - min_elev_at_edge)
	var total: int = base_range + elev_bonus
	# Night penalty
	if _is_night() and not _unit_has_night_vision(unit):
		total = maxi(1, int(float(total) * night_spotting_modifier))
	return total


func consume_ammo_conservation(current_ammo: int, max_ammo: int) -> float:
	var ammo_pct: float = float(current_ammo) / maxf(1.0, float(max_ammo))
	var conservation: float = 1.0
	if ammo_pct < 0.5:
		# Linear taper: at 50% fire at full rate, at 10% fire at 20%, at 0% don't fire
		conservation = clampf(ammo_pct / 0.5, 0.2, 1.0)
	return conservation


# ---------------------------------------------------------------------------
# Morale functions
# ---------------------------------------------------------------------------

func check_morale(unit: Dictionary) -> void:
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var base_morale: int = int(utype.get("morale", 50))
	var morale_dmg: int = int(unit.get("morale_damage", 0))
	var penalty: int = morale_dmg + get_ammo_morale_penalty(unit)

	# Mobility damage penalty - being immobilised in a technical is terrifying
	var mob_dmg: float = float(unit.get("mobility_damage", 0.0))
	if mob_dmg >= 1.0:
		penalty += 15  # immobilised - sitting duck
	elif mob_dmg > 0.5:
		penalty += 8
	elif mob_dmg > 0.0:
		penalty += 3

	# Suppression penalty (proportional, not stepped)
	var uname: String = unit.get("name", "")
	var supp: float = combat.get_suppression(uname)
	penalty += int(supp * 0.3)  # 100% suppression = -30 morale

	# No HQ penalty - fighting alone is demoralising
	if not unit.get("in_comms", false) and not utype.get("is_hq", false):
		penalty += 10

	# Crew loss penalty (proportional)
	var max_crew: int = int(utype.get("crew", 4))
	var cur_crew: int = int(unit.get("current_crew", max_crew))
	if max_crew > 0:
		var crew_lost_pct: float = 1.0 - (float(cur_crew) / float(max_crew))
		penalty += int(crew_lost_pct * 40)  # all crew dead = -40

	# Proximity to enemy while damaged - sitting duck panic
	var vdmg: float = float(unit.get("vehicle_damage", 0.0))
	if vdmg > 0.3 or mob_dmg > 0.3:
		var unit_pos_check: Vector2i = Vector2i(unit["col"], unit["row"])
		var unit_side_check: String = unit.get("side", "player")
		var enemy_close: bool = false
		for other in units:
			if other.get("side", "player") == unit_side_check:
				continue
			if other.get("unit_status", "") == "DESTROYED":
				continue
			var other_pos: Vector2i = Vector2i(other["col"], other["row"])
			if hex_grid.hex_distance(unit_pos_check, other_pos) <= 3:
				enemy_close = true
				break
		if enemy_close:
			var damage_panic: int = int((vdmg + mob_dmg) * 15)
			penalty += damage_panic

	# Elevation morale modifier: high ground gives confidence, low ground penalizes
	var elev_bonus: int = 0
	if supp > 0.0:
		var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
		var unit_elev: int = elevation_grid[unit_pos.y][unit_pos.x]
		var unit_side: String = unit.get("side", "player")
		var unit_type_info: Dictionary = unit_types.get(utype_code, {})
		var spot_range: int = get_effective_spotting_range(unit)
		var highest_enemy_elev: int = -999
		var found_enemy: bool = false
		for other in units:
			if other.get("side", "player") == unit_side:
				continue
			if other.get("unit_status", "") == "DESTROYED":
				continue
			var other_pos: Vector2i = Vector2i(other["col"], other["row"])
			if hex_grid.hex_distance(unit_pos, other_pos) <= spot_range:
				var other_elev: int = elevation_grid[other_pos.y][other_pos.x]
				if other_elev > highest_enemy_elev:
					highest_enemy_elev = other_elev
				found_enemy = true
		if found_enemy:
			var elev_advantage: int = unit_elev - highest_enemy_elev
			elev_bonus = elev_advantage * 5  # +5 per level above, -5 per level below

	var effective_morale: int = maxi(0, base_morale - penalty + elev_bonus)
	if unit.get("in_hq_los", false):
		effective_morale += hq_los_morale_buff
	unit["current_morale"] = effective_morale

	var status: String = unit.get("unit_status", "")
	if status == "DESTROYED" or status == "IMMOBILISED":
		return
	if effective_morale < MORALE_ROUT_THRESHOLD and status != "ROUTING":
		unit["unit_status"] = "ROUTING"
		start_rout(unit)
		combat.log_event("%s is ROUTING!" % uname)
	elif effective_morale < MORALE_BREAK_THRESHOLD and status != "ROUTING" and status != "BROKEN":
		unit["unit_status"] = "BROKEN"
		start_break(unit)
		combat.log_event("%s has BROKEN!" % uname)
	elif status == "ROUTING" or status == "BROKEN":
		# Check if routing/broken unit has stopped but enemies are still nearby
		var uname_check: String = unit.get("name", "")
		var order_check: Order = order_manager.get_order(uname_check)
		if order_check == null or order_check.status == Order.Status.COMPLETE:
			var unit_pos_check: Vector2i = Vector2i(unit["col"], unit["row"])
			var enemies_near: bool = false
			for other in units:
				if other.get("side", "player") == unit.get("side", "player"):
					continue
				if other.get("unit_status", "") == "DESTROYED":
					continue
				if hex_grid.hex_distance(unit_pos_check, Vector2i(other["col"], other["row"])) <= 4:
					enemies_near = true
					break
			if enemies_near:
				if status == "ROUTING":
					start_rout(unit)
				else:
					start_break(unit)
		# Rally check - only if morale recovered enough
		if effective_morale >= MORALE_BREAK_THRESHOLD:
			unit["unit_status"] = ""
			combat.log_event("%s has rallied" % uname)


func recover_morale(unit: Dictionary, minutes: float) -> void:
	var status: String = unit.get("unit_status", "")
	if status == "DESTROYED":
		return

	var uname: String = unit.get("name", "")
	var supp: float = combat.get_suppression(uname)
	if supp > 0.0:
		# Still under fire - no recovery, reset accumulator
		unit["morale_recovery_accum"] = 0.0
		return

	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var base_morale: int = int(utype.get("morale", 50))
	var recovery_rate: float = float(utype.get("morale_recovery_per_min", 1.0))
	var current: int = int(unit.get("current_morale", base_morale))

	if current >= base_morale:
		return  # Already at max

	var accum: float = float(unit.get("morale_recovery_accum", 0.0))
	accum += recovery_rate * minutes
	if accum >= 1.0:
		var gain: int = int(accum)
		current = mini(current + gain, base_morale)
		unit["current_morale"] = current
		accum -= float(gain)

		# Recover from broken/routing if morale is high enough
		if status == "BROKEN" and current >= MORALE_BREAK_THRESHOLD:
			unit["unit_status"] = ""
			combat.log_event("%s has rallied" % uname)
		elif status == "ROUTING" and current >= MORALE_BREAK_THRESHOLD:
			unit["unit_status"] = ""
			combat.log_event("%s has rallied from rout" % uname)

	unit["morale_recovery_accum"] = accum


func get_ammo_morale_penalty(unit: Dictionary) -> int:
	var ammo_arr: Array = unit.get("current_ammo", [])
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})
	var weapons: Array = utype.get("weapons", [])
	if not (weapons is Array) or weapons.is_empty():
		return 0

	# Use average ammo percentage across all weapons
	var total_pct: float = 0.0
	var count: int = 0
	var all_empty: bool = true
	for i in range(ammo_arr.size()):
		var max_ammo: int = 0
		if i < weapons.size():
			max_ammo = int(weapons[i].get("ammo", 0))
		if max_ammo <= 0:
			continue
		var cur: int = int(ammo_arr[i])
		if cur > 0:
			all_empty = false
		total_pct += float(cur) / float(max_ammo)
		count += 1

	if all_empty and count > 0:
		return 25
	if count == 0:
		return 0
	var avg_pct: float = total_pct / float(count)
	if avg_pct < 0.15:
		return 15
	elif avg_pct < 0.30:
		return 10
	elif avg_pct < 0.50:
		return 5
	return 0


func get_lowest_ammo_pct(unit: Dictionary) -> float:
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


# ---------------------------------------------------------------------------
# Destruction functions
# ---------------------------------------------------------------------------

func abandon_vehicle(unit: Dictionary) -> void:
	var uname: String = unit.get("name", "?")
	combat.log_event("%s crew abandoning vehicle!" % uname)

	# Mark the vehicle as destroyed - zero out crew and morale
	unit["unit_status"] = "DESTROYED"
	unit["current_crew"] = 0
	unit["current_morale"] = 0
	order_manager.cancel_order(uname)

	# Place death marker for the vehicle (stays for 2 hours)
	var pos: Vector2i = Vector2i(unit["col"], unit["row"])
	death_markers[pos] = game_clock.game_time_minutes

	# Create a dismounted crew unit in its place
	var crew_left: int = int(unit.get("current_crew", 1))
	var side: String = unit.get("side", "player")
	var assigned_hq: String = unit.get("assigned_hq", "")
	var infantry_name: String = uname + " (dismounted)"

	# Carry over rifle ammo from the vehicle
	var old_ammo: Array = unit.get("current_ammo", [])
	var old_utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
	var old_weapons: Array = old_utype.get("weapons", [])
	if not (old_weapons is Array):
		old_weapons = []
	var carried_rifle_ammo: int = 0
	for wi in range(old_weapons.size()):
		var w: Dictionary = old_weapons[wi]
		if str(w.get("type", "")) == "rifle" and wi < old_ammo.size():
			carried_rifle_ammo += int(old_ammo[wi])

	var infantry: Dictionary = {
		"type_code": "INF",
		"col": pos.x,
		"row": pos.y,
		"name": infantry_name,
		"side": side,
		"default_roe": "return fire",
	}
	_init_unit_ammo_and_morale(infantry)

	# Override with carried ammo and crew count
	infantry["current_crew"] = crew_left
	infantry["current_morale"] = 10
	infantry["morale_damage"] = 35
	var inf_ammo: Array = infantry.get("current_ammo", [])
	if inf_ammo.size() > 0:
		inf_ammo[0] = mini(carried_rifle_ammo, 360)
	infantry["current_ammo"] = inf_ammo

	if assigned_hq != "":
		infantry["assigned_hq"] = assigned_hq

	units.append(infantry)

	# Immediately start routing
	infantry["unit_status"] = "ROUTING"
	start_rout(infantry)

	# Trigger destruction morale shock for the vehicle loss
	on_unit_destroyed(unit)

	combat.log_event("%s: %d crew dismounted, routing on foot" % [infantry_name, crew_left])


func on_unit_destroyed(dead_unit: Dictionary) -> void:
	var dead_pos: Vector2i = Vector2i(dead_unit["col"], dead_unit["row"])
	var dead_side: String = dead_unit.get("side", "player")

	# Add death marker
	death_markers[dead_pos] = game_clock.game_time_minutes

	# Apply morale shock to friendly units
	var dead_hq_name: String = dead_unit.get("assigned_hq", "")
	for unit in units:
		if unit.get("side", "player") != dead_side:
			continue
		if unit.get("unit_status", "") == "DESTROYED":
			continue
		var uname: String = unit.get("name", "")
		var shock: int = 0

		# Direct HQ takes the biggest hit
		if uname == dead_hq_name:
			shock = destruction_direct_hq_shock
		else:
			# Check if this unit's HQ is the dead unit's HQ (sibling unit)
			var unit_hq: String = unit.get("assigned_hq", "")
			if unit_hq == dead_hq_name and dead_hq_name != "":
				shock = destruction_direct_hq_shock / 2  # sibling lost

			# Parent HQ
			var dead_unit_hq_unit: Dictionary = {}
			for other in units:
				if other.get("name", "") == dead_hq_name:
					dead_unit_hq_unit = other
					break
			if not dead_unit_hq_unit.is_empty():
				var parent_hq: String = dead_unit_hq_unit.get("assigned_hq", "")
				if uname == parent_hq:
					shock = maxi(shock, destruction_parent_hq_shock)

		# Anyone with LOS to the death
		if shock == 0:
			var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
			var spot_range: int = get_effective_spotting_range(unit)
			if hex_grid.hex_distance(unit_pos, dead_pos) <= spot_range:
				var unit_elev: int = elevation_grid[unit_pos.y][unit_pos.x]
				if hex_grid.has_los(unit_pos, unit_elev, dead_pos):
					shock = destruction_los_witness_shock

		if shock > 0:
			var cur_dmg: int = int(unit.get("morale_damage", 0))
			unit["morale_damage"] = cur_dmg + shock
			combat.log_event("%s morale shocked (-%d) by destruction of %s" % [
				uname, shock, dead_unit.get("name", "?")])


# ---------------------------------------------------------------------------
# Break / rout / pursuit
# ---------------------------------------------------------------------------

func start_break(unit: Dictionary) -> void:
	var uname: String = unit.get("name", "")
	order_manager.cancel_order(uname)
	# Break: driver bolts cautiously - no staff delay, immediate execution
	var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
	var flee_hex: Vector2i = _flee_target(unit_pos, 3)
	order_manager.issue_immediate_order(unit, Order.Type.WITHDRAW, flee_hex,
		Order.Posture.CAUTIOUS, Order.ROE.HOLD_FIRE, game_clock.game_time_minutes)


func start_rout(unit: Dictionary) -> void:
	var uname: String = unit.get("name", "")
	order_manager.cancel_order(uname)
	# Rout: driver floors it - no staff delay, immediate execution
	var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
	var flee_hex: Vector2i = _flee_target(unit_pos, 5)
	order_manager.issue_immediate_order(unit, Order.Type.WITHDRAW, flee_hex,
		Order.Posture.FAST, Order.ROE.HOLD_FIRE, game_clock.game_time_minutes)


func check_pursuit() -> void:
	for unit in units:
		if unit.get("side", "player") != "player":
			continue
		# HQ units never pursue
		var utype: Dictionary = unit_types.get(unit.get("type_code", ""), {})
		if utype.get("is_hq", false):
			continue
		var status: String = unit.get("unit_status", "")
		if status == "DESTROYED" or status == "BROKEN" or status == "ROUTING":
			continue

		var uname: String = unit.get("name", "")
		var order: Order = order_manager.get_order(uname)
		if order == null:
			continue

		var pursuit_mode: Order.Pursuit = order.pursuit
		if pursuit_mode == Order.Pursuit.HOLD:
			continue

		# Check if unit is already pursuing
		if unit.get("pursuing", "") != "":
			# Verify target still visible and still fleeing
			var target_name: String = unit.get("pursuing", "")
			var target_unit: Dictionary = {}
			for other in units:
				if other.get("name", "") == target_name:
					target_unit = other
					break
			if target_unit.is_empty() or target_unit.get("unit_status", "") == "DESTROYED":
				unit["pursuing"] = ""
				continue
			# Check still in spotting range
			var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
			var target_pos: Vector2i = Vector2i(target_unit["col"], target_unit["row"])
			var spot_range: int = get_effective_spotting_range(unit)
			if hex_grid.hex_distance(unit_pos, target_pos) > spot_range:
				unit["pursuing"] = ""
				continue
			# Check still in HQ comms range
			if not unit.get("in_comms", false):
				unit["pursuing"] = ""
				continue
			# Check target still broken/routing
			var t_status: String = target_unit.get("unit_status", "")
			if t_status != "BROKEN" and t_status != "ROUTING":
				unit["pursuing"] = ""
				continue
			# Update pursuit waypoint
			update_pursuit_target(unit, target_unit, pursuit_mode)
			continue

		# Look for a broken/routing enemy to pursue
		var targets: Array = find_targets_in_range(unit)
		for target in targets:
			var t_status: String = target.get("unit_status", "")
			if t_status == "BROKEN" or t_status == "ROUTING":
				# Check we'd stay in comms range
				if not unit.get("in_comms", false):
					continue
				unit["pursuing"] = target.get("name", "")
				update_pursuit_target(unit, target, pursuit_mode)
				combat.log_event("%s pursuing %s (%s)" % [
					uname, target.get("name", "?"),
					Order.pursuit_to_string(pursuit_mode).to_upper()])
				break


func update_pursuit_target(unit: Dictionary, target: Dictionary, pursuit_mode: Order.Pursuit) -> void:
	var uname: String = unit.get("name", "")
	var unit_pos: Vector2i = Vector2i(unit["col"], unit["row"])
	var target_pos: Vector2i = Vector2i(target["col"], target["row"])
	var utype_code: String = unit.get("type_code", "")
	var utype: Dictionary = unit_types.get(utype_code, {})

	# Check HQ comms range - don't pursue beyond it
	var assigned_hq_name: String = unit.get("assigned_hq", "")
	if assigned_hq_name != "":
		var hq_unit: Dictionary = {}
		for other in units:
			if other.get("name", "") == assigned_hq_name:
				hq_unit = other
				break
		if not hq_unit.is_empty():
			var hq_type: Dictionary = unit_types.get(hq_unit.get("type_code", ""), {})
			var comms_data = hq_type.get("comms", {})
			if comms_data is Dictionary:
				var comms_range: float = float(comms_data.get("range_km", 0)) / 0.5
				var hq_pos: Vector2i = Vector2i(hq_unit["col"], hq_unit["row"])
				if float(hex_grid.hex_distance(target_pos, hq_pos)) > comms_range:
					# Target is outside comms range - don't pursue there
					unit["pursuing"] = ""
					return

	match pursuit_mode:
		Order.Pursuit.SHADOW:
			# Stay at spotting range - move to keep target at edge of vision
			var spot_range: int = get_effective_spotting_range(unit)
			var dist: int = hex_grid.hex_distance(unit_pos, target_pos)
			if dist > spot_range - 1:
				# Need to close distance to keep in sight
				order_manager.issue_immediate_order(unit, Order.Type.MOVE, target_pos,
					Order.Posture.CAUTIOUS, Order.ROE.RETURN_FIRE, game_clock.game_time_minutes)
		Order.Pursuit.PRESS:
			# Close in aggressively
			order_manager.issue_immediate_order(unit, Order.Type.MOVE, target_pos,
				Order.Posture.FAST, Order.ROE.FIRE_AT_WILL, game_clock.game_time_minutes)


# ---------------------------------------------------------------------------
# Private helpers (pathfinding delegates stay in hex_map.gd)
# ---------------------------------------------------------------------------

func _flee_target(from: Vector2i, distance: int) -> Vector2i:
	## Find a hex roughly `distance` hexes toward the nearest map edge
	var edge: Vector2i = hex_grid.nearest_edge_hex(from)
	# Walk toward edge but only `distance` steps
	var current: Vector2i = from
	for _i in range(distance):
		var next: Vector2i = _next_step_toward(current, edge)
		if next == current:
			break
		current = next
	return current


func _next_step_toward(from: Vector2i, to: Vector2i) -> Vector2i:
	## Simple greedy step toward target - used only for flee/rout pathfinding.
	var neighbors: Array[Vector2i] = hex_grid.get_hex_neighbors(from)
	var best: Vector2i = from
	var best_dist: int = hex_grid.hex_distance(from, to)
	for n in neighbors:
		if n.x < 0 or n.x >= map_cols or n.y < 0 or n.y >= map_rows:
			continue
		var n_terrain: String = terrain_grid[n.y][n.x]
		if n_terrain in terrain_types:
			var speed_mod: float = float(terrain_types[n_terrain].get("speed_modifier", 1.0))
			if speed_mod <= 0.0:
				continue
		var dist: int = hex_grid.hex_distance(n, to)
		if dist < best_dist:
			best_dist = dist
			best = n
	return best


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
	unit["vehicle_damage"] = 0.0
	unit["mobility_damage"] = 0.0
	unit["unit_status"] = ""
	unit["morale_recovery_accum"] = 0.0
	unit["morale_damage"] = 0
	unit["assigned_hq"] = ""
	unit["in_comms"] = false
	unit["in_hq_los"] = false
	unit["hq_switch_remaining"] = 0.0
