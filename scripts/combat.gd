class_name Combat
extends RefCounted

## Resolves individual shots between units.
## Call resolve_combat() each game tick with elapsed minutes.

# Base hit chance by training level (at optimal range, stationary)
const TRAINING_ACCURACY := {
	"militia": 0.05,
	"irregular": 0.10,
	"regular": 0.18,
	"veteran": 0.25,
	"elite": 0.35,
}

# Combat log for display
var combat_log: Array[String] = []

# Suppression per unit (keyed by unit name) - accumulated incoming fire pressure
# Decays over time, affects accuracy and morale
var suppression: Dictionary = {}  # String -> float (0.0 to 100.0)

const SUPPRESSION_DECAY_PER_MIN := 5.0
const SUPPRESSION_PER_HIT_NEAR := 12.0   # round lands near (miss) - HMG near misses are terrifying
const SUPPRESSION_PER_HIT := 15.0        # actual hit


func resolve_combat(shooter: Dictionary, target: Dictionary,
		shooter_type: Dictionary, target_type: Dictionary,
		weapon_index: int, rounds_fired: int,
		distance_hexes: int, shooter_moving: bool, target_moving: bool,
		target_terrain: String, target_armor: int,
		is_suppressive: bool = false, elevation_diff: int = 0,
		accuracy_modifier: float = 1.0) -> Dictionary:
	## Returns {hits: int, crew_killed: int, vehicle_damage: float, suppression_added: float}

	var result := {
		"hits": 0,
		"crew_killed": 0,
		"vehicle_damage": 0.0,
		"suppression_added": 0.0,
		"mobility_damage": 0.0,
		"weapon_disabled": false,
	}

	if rounds_fired <= 0:
		return result

	var weapons: Array = shooter_type.get("weapons", [])
	if weapon_index >= weapons.size():
		return result
	var weapon: Dictionary = weapons[weapon_index]

	var training: String = str(shooter_type.get("training", "regular"))
	var base_accuracy: float = TRAINING_ACCURACY.get(training, 0.15)

	# Elevation modifier on accuracy: +5% per level above, -5% per level below
	var elev_accuracy_mult: float = clampf(1.0 + elevation_diff * 0.05, 0.7, 1.5)
	base_accuracy *= elev_accuracy_mult

	# Range modifier: accuracy degrades with distance
	var max_range_km: float = float(weapon.get("range_km", 1.0))
	if shooter_moving:
		max_range_km = float(weapon.get("range_moving_km", max_range_km * 0.3))
	var max_range_hexes: float = max_range_km / 0.5

	# Shooting downhill slightly extends effective range (up to 1.2x)
	if elevation_diff > 0:
		var range_ext: float = clampf(1.0 + elevation_diff * 0.03, 1.0, 1.2)
		max_range_hexes *= range_ext

	var range_factor: float = 1.0
	if max_range_hexes > 0:
		range_factor = clampf(1.0 - (float(distance_hexes) / max_range_hexes) * 0.7, 0.1, 1.0)

	# Movement penalties
	var move_penalty: float = 1.0
	if shooter_moving:
		move_penalty *= 0.3  # shooting from a moving vehicle is hard
	if target_moving:
		move_penalty *= 0.6  # moving target is harder to hit

	# Cover from terrain
	var cover_factor: float = 1.0
	match target_terrain:
		"W": cover_factor = 0.3   # woods - lots of cover
		"T": cover_factor = 0.4   # town - buildings
		"C": cover_factor = 0.35  # city - dense urban
		"O": cover_factor = 1.0   # open - no cover
		"S": cover_factor = 0.9   # street - minimal cover

	# Target concealment - high concealment units (infantry in cover) are very hard to hit
	var target_concealment: int = int(target_type.get("concealment", 2))
	var concealment_factor: float = clampf(1.0 - float(target_concealment) * 0.07, 0.15, 1.0)
	# Concealment is much more effective in cover terrain
	if target_terrain == "W" or target_terrain == "T" or target_terrain == "C":
		concealment_factor *= clampf(1.0 - float(target_concealment) * 0.05, 0.1, 1.0)

	# Suppression penalty on shooter
	var shooter_name: String = shooter.get("name", "")
	var shooter_suppression: float = suppression.get(shooter_name, 0.0)
	var suppression_factor: float = clampf(1.0 - (shooter_suppression / 60.0) * (shooter_suppression / 60.0), 0.05, 1.0)

	# Suppressive fire penalty - still adds suppression but very unlikely to hit
	var suppressive_penalty: float = 1.0
	if is_suppressive:
		suppressive_penalty = 0.15

	# Platform accuracy modifier (vehicle-mounted weapons are less accurate)
	# But handheld weapons (rifles) fired from a stationary position ignore platform penalty
	var platform_accuracy: float = float(weapon.get("platform_accuracy", 1.0))
	var weapon_type: String = str(weapon.get("type", ""))
	if not shooter_moving and (weapon_type == "rifle" or weapon_type == "rpg"):
		platform_accuracy = 1.0

	# Close range bonus: within 1 hex (500m), a vehicle is a huge target
	# Within 2 hexes (1km), still significantly easier
	var close_range_bonus: float = 1.0
	if distance_hexes <= 1:
		close_range_bonus = 2.5  # 500m at a truck - hard to miss
	elif distance_hexes <= 2:
		close_range_bonus = 1.5

	# Final hit probability per round
	var hit_chance: float = base_accuracy * range_factor * move_penalty * cover_factor * concealment_factor * suppression_factor * suppressive_penalty * platform_accuracy * accuracy_modifier * close_range_bonus
	hit_chance = clampf(hit_chance, 0.001, 0.8)  # floor and ceiling

	# Resolve each shot
	var vs_soft: int = int(weapon.get("vs_soft", 3))
	var vs_armor: int = int(weapon.get("vs_armor", 0))

	for _i in range(rounds_fired):
		var roll: float = randf()

		if roll < hit_chance:
			# Hit!
			result["hits"] += 1
			result["suppression_added"] += SUPPRESSION_PER_HIT

			# Determine effect using hit zone distribution
			if target_armor > 0:
				# Armored target - check penetration first, no close range bonus
				var pen_chance: float = clampf(float(vs_armor) / float(target_armor + vs_armor), 0.0, 0.9)
				if randf() < pen_chance:
					_apply_hit_zone(result, vs_soft)
			else:
				# Unarmored vehicle - close range is devastating
				_apply_hit_zone(result, vs_soft, distance_hexes)
		else:
			# Miss but near misses still suppress
			if roll < hit_chance * 3.0:
				result["suppression_added"] += SUPPRESSION_PER_HIT_NEAR

	return result


func _apply_hit_zone(result: Dictionary, vs_soft: int, distance: int = 3) -> void:
	## Distributes a hit across vehicle hit zones.
	## At close range (<=1 hex), damage values are higher and crew hits more likely.
	var close := distance <= 1
	var dmg_mult: float = 1.5 if close else 1.0

	# At close range, more crew exposure (they can't hide behind the engine block)
	var zone_roll: float = randf()
	if close:
		# Close range: 35% body, 20% mobility, 10% weapon, 25% crew, 10% catastrophic
		# Rifle rounds punch through sheet metal easily at 500m
		if zone_roll < 0.35:
			result["vehicle_damage"] += randf_range(0.10, 0.25) * dmg_mult
		elif zone_roll < 0.55:
			result["mobility_damage"] += randf_range(0.20, 0.45)
			result["vehicle_damage"] += randf_range(0.05, 0.12)
		elif zone_roll < 0.65:
			result["weapon_disabled"] = true
			result["vehicle_damage"] += randf_range(0.03, 0.10)
		elif zone_roll < 0.90:
			var kill_chance: float = clampf(float(vs_soft) / 10.0, 0.15, 0.95)
			if randf() < kill_chance:
				result["crew_killed"] += 1
		else:
			result["vehicle_damage"] += randf_range(0.3, 0.5)
			result["mobility_damage"] += randf_range(0.2, 0.4)
			if randf() < 0.6:
				result["crew_killed"] += 1
	else:
		# Normal range: 50% body, 20% mobility, 15% weapon, 10% crew, 5% catastrophic
		if zone_roll < 0.50:
			result["vehicle_damage"] += randf_range(0.05, 0.15)
		elif zone_roll < 0.70:
			result["mobility_damage"] += randf_range(0.15, 0.35)
			result["vehicle_damage"] += randf_range(0.02, 0.08)
		elif zone_roll < 0.85:
			result["weapon_disabled"] = true
			result["vehicle_damage"] += randf_range(0.03, 0.10)
		elif zone_roll < 0.95:
			var kill_chance: float = clampf(float(vs_soft) / 10.0, 0.1, 0.9)
			if randf() < kill_chance:
				result["crew_killed"] += 1
		else:
			result["vehicle_damage"] += randf_range(0.3, 0.5)
			result["mobility_damage"] += randf_range(0.2, 0.4)
			if randf() < 0.5:
				result["crew_killed"] += 1


func apply_suppression(unit_name: String, amount: float) -> void:
	var current: float = suppression.get(unit_name, 0.0)
	suppression[unit_name] = clampf(current + amount, 0.0, 100.0)


func get_suppression(unit_name: String) -> float:
	return suppression.get(unit_name, 0.0)


func decay_suppression(minutes: float) -> void:
	var decay := SUPPRESSION_DECAY_PER_MIN * minutes
	var to_remove: Array[String] = []
	for unit_name in suppression:
		var val: float = suppression[unit_name]
		val = maxf(0.0, val - decay)
		if val <= 0.0:
			to_remove.append(unit_name)
		else:
			suppression[unit_name] = val
	for name in to_remove:
		suppression.erase(name)


func log_event(msg: String) -> void:
	combat_log.append(msg)
	if combat_log.size() > 100:
		combat_log.remove_at(0)
