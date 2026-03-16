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
const SUPPRESSION_PER_HIT_NEAR := 8.0   # round lands near (miss)
const SUPPRESSION_PER_HIT := 15.0        # actual hit


func resolve_combat(shooter: Dictionary, target: Dictionary,
		shooter_type: Dictionary, target_type: Dictionary,
		weapon_index: int, rounds_fired: int,
		distance_hexes: int, shooter_moving: bool, target_moving: bool,
		target_terrain: String, target_armor: int,
		is_suppressive: bool = false, elevation_diff: int = 0) -> Dictionary:
	## Returns {hits: int, crew_killed: int, vehicle_damage: float, suppression_added: float}

	var result := {
		"hits": 0,
		"crew_killed": 0,
		"vehicle_damage": 0.0,
		"suppression_added": 0.0,
	}

	if rounds_fired <= 0:
		return result

	var weapons: Array = shooter_type.get("weapons", [])
	if weapon_index >= weapons.size():
		return result
	var weapon: Dictionary = weapons[weapon_index]

	var training: String = str(shooter_type.get("training", "regular"))
	var base_accuracy: float = TRAINING_ACCURACY.get(training, 0.15)

	# Elevation modifier on accuracy: +15% per level above, -15% per level below
	var elev_accuracy_mult: float = clampf(1.0 + elevation_diff * 0.15, 0.5, 2.0)
	base_accuracy *= elev_accuracy_mult

	# Range modifier: accuracy degrades with distance
	var max_range_km: float = float(weapon.get("range_km", 1.0))
	if shooter_moving:
		max_range_km = float(weapon.get("range_moving_km", max_range_km * 0.3))
	var max_range_hexes: float = max_range_km / 0.5

	# Shooting downhill extends effective range (up to 1.5x)
	if elevation_diff > 0:
		var range_ext: float = clampf(1.0 + elevation_diff * 0.1, 1.0, 1.5)
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

	# Suppression penalty on shooter
	var shooter_name: String = shooter.get("name", "")
	var shooter_suppression: float = suppression.get(shooter_name, 0.0)
	var suppression_factor: float = clampf(1.0 - shooter_suppression / 100.0, 0.1, 1.0)

	# Suppressive fire penalty - still adds suppression but very unlikely to hit
	var suppressive_penalty: float = 1.0
	if is_suppressive:
		suppressive_penalty = 0.15

	# Final hit probability per round
	var hit_chance: float = base_accuracy * range_factor * move_penalty * cover_factor * suppression_factor * suppressive_penalty
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

			# Determine effect
			if target_armor > 0:
				# Armored target - check penetration
				var pen_chance: float = clampf(float(vs_armor) / float(target_armor + vs_armor), 0.0, 0.9)
				if randf() < pen_chance:
					# Penetration - crew casualty or vehicle damage
					if randf() < 0.4:
						result["crew_killed"] += 1
					result["vehicle_damage"] += randf_range(0.1, 0.3)
			else:
				# Unarmored - very vulnerable
				# vs_soft determines lethality
				var kill_chance: float = clampf(float(vs_soft) / 10.0, 0.1, 0.9)
				if randf() < kill_chance:
					result["crew_killed"] += 1
				# Vehicle always takes damage from hits on unarmored
				result["vehicle_damage"] += randf_range(0.05, 0.15)
		else:
			# Miss but near misses still suppress
			if roll < hit_chance * 3.0:
				result["suppression_added"] += SUPPRESSION_PER_HIT_NEAR

	return result


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
