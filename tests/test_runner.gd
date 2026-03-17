extends SceneTree

## Simple test runner. Run with: godot --headless --script tests/test_runner.gd

var tests_run: int = 0
var tests_passed: int = 0
var tests_failed: int = 0


func _init() -> void:
	print("=== Running Tests ===\n")

	_test_hex_grid()
	_test_order()
	_test_combat()
	_test_movement_pathfinding()
	_test_yaml_parser()
	_test_hq_comms()
	_test_combat_resolver()

	print("\n=== Results: %d passed, %d failed, %d total ===" % [
		tests_passed, tests_failed, tests_run])

	if tests_failed > 0:
		quit(1)
	else:
		quit(0)


func assert_eq(actual: Variant, expected: Variant, desc: String) -> void:
	tests_run += 1
	if actual == expected:
		tests_passed += 1
	else:
		tests_failed += 1
		print("  FAIL: %s -- expected %s, got %s" % [desc, str(expected), str(actual)])


func assert_true(val: bool, desc: String) -> void:
	tests_run += 1
	if val:
		tests_passed += 1
	else:
		tests_failed += 1
		print("  FAIL: %s" % desc)


func assert_range(val: float, low: float, high: float, desc: String) -> void:
	tests_run += 1
	if val >= low and val <= high:
		tests_passed += 1
	else:
		tests_failed += 1
		print("  FAIL: %s -- expected %.2f-%.2f, got %.2f" % [desc, low, high, val])


# ============================================================
# HexGrid tests
# ============================================================
func _test_hex_grid() -> void:
	print("--- HexGrid ---")

	# Create a small test grid
	var terrain: Array = []
	var elevation: Array = []
	for r in range(10):
		var trow: Array[String] = []
		var erow: Array[int] = []
		for c in range(10):
			trow.append("O")
			erow.append(5)
		terrain.append(trow)
		elevation.append(erow)

	var grid := HexGrid.new(terrain, elevation, 10, 10, 40.0)

	# Distance
	assert_eq(grid.hex_distance(Vector2i(0, 0), Vector2i(0, 0)), 0, "distance to self")
	assert_eq(grid.hex_distance(Vector2i(0, 0), Vector2i(1, 0)), 1, "adjacent hex distance")
	assert_true(grid.hex_distance(Vector2i(0, 0), Vector2i(5, 5)) > 0, "nonzero distance")

	# Cube conversion roundtrip
	var hex := Vector2i(3, 4)
	var cube: Vector3i = grid.offset_to_cube(hex)
	var back: Vector2i = grid.cube_to_offset(cube)
	assert_eq(back, hex, "cube roundtrip")

	# Valid hex
	assert_true(grid.is_valid_hex(Vector2i(0, 0)), "origin valid")
	assert_true(grid.is_valid_hex(Vector2i(9, 9)), "corner valid")
	assert_true(not grid.is_valid_hex(Vector2i(-1, 0)), "negative invalid")
	assert_true(not grid.is_valid_hex(Vector2i(10, 5)), "out of bounds invalid")

	# Neighbors
	var neighbors: Array[Vector2i] = grid.get_hex_neighbors(Vector2i(5, 5))
	assert_eq(neighbors.size(), 6, "6 neighbors")

	# LOS - flat terrain, no obstacles
	assert_true(grid.has_los(Vector2i(2, 2), 5, Vector2i(5, 5)), "LOS on flat terrain")

	# LOS blocked by high terrain
	elevation[3][3] = 9  # wall
	elevation[3][4] = 9
	assert_true(not grid.has_los(Vector2i(2, 2), 5, Vector2i(5, 5)), "LOS blocked by high terrain")

	# Pixel conversion roundtrip
	var pixel: Vector2 = grid.hex_to_pixel(4, 3)
	var back_hex: Vector2i = grid.pixel_to_hex(pixel)
	assert_eq(back_hex, Vector2i(4, 3), "pixel roundtrip")

	# Nearest edge hex
	var edge: Vector2i = grid.nearest_edge_hex(Vector2i(1, 5))
	assert_eq(edge.x, 0, "nearest edge is left")

	# Find open hex
	var open: Vector2i = grid.find_open_hex_near(5, 5)
	assert_true(open != Vector2i(-1, -1), "found open hex")

	print("  HexGrid: done")


# ============================================================
# Order tests
# ============================================================
func _test_order() -> void:
	print("--- Order ---")

	var order := Order.new()
	assert_true(order.is_empty(), "new order is empty")

	order.add_waypoint(Vector2i(5, 5), Order.Posture.FAST, Order.ROE.FIRE_AT_WILL, Order.Pursuit.PRESS)
	assert_eq(order.waypoint_count(), 1, "1 waypoint")
	assert_eq(order.current_target(), Vector2i(5, 5), "current target")
	assert_eq(order.posture, Order.Posture.FAST, "posture from waypoint")
	assert_eq(order.roe, Order.ROE.FIRE_AT_WILL, "ROE from waypoint")
	assert_eq(order.pursuit, Order.Pursuit.PRESS, "pursuit from waypoint")

	order.add_waypoint(Vector2i(8, 3), Order.Posture.CAUTIOUS, Order.ROE.HOLD_FIRE)
	assert_eq(order.waypoint_count(), 2, "2 waypoints")
	assert_eq(order.current_target(), Vector2i(5, 5), "still first waypoint")

	order.advance_waypoint()
	assert_eq(order.current_target(), Vector2i(8, 3), "advanced to second")
	assert_eq(order.posture, Order.Posture.CAUTIOUS, "posture changed after advance")

	# Target hex is last waypoint
	assert_eq(order.target_hex, Vector2i(8, 3), "target_hex is last waypoint")

	# Remove last waypoint
	order.remove_last_waypoint()
	assert_eq(order.waypoint_count(), 1, "removed last waypoint")

	# String conversions
	assert_eq(Order.posture_to_string(Order.Posture.FAST), "fast", "posture to string")
	assert_eq(Order.roe_to_string(Order.ROE.HALT_AND_ENGAGE), "halt & engage", "ROE to string")
	assert_eq(Order.pursuit_to_string(Order.Pursuit.SHADOW), "shadow", "pursuit to string")
	assert_eq(Order.type_to_string(Order.Type.MOVE), "move", "type to string")

	# Status update
	var timed := Order.new()
	timed.issued_at = 0.0
	timed.formulation_time = 10.0
	timed.preparation_time = 5.0
	timed.add_waypoint(Vector2i(1, 1), Order.Posture.NORMAL)
	assert_eq(timed.status, Order.Status.FORMULATING, "starts formulating")
	timed.update(10.0)
	assert_eq(timed.status, Order.Status.PREPARING, "preparing after formulation")
	timed.update(15.0)
	assert_eq(timed.status, Order.Status.EXECUTING, "executing after preparation")

	print("  Order: done")


# ============================================================
# Combat (shot resolution) tests
# ============================================================
func _test_combat() -> void:
	print("--- Combat ---")

	var c := Combat.new()

	var shooter := {"name": "test_shooter"}
	var target := {"name": "test_target"}
	var shooter_type := {
		"training": "regular",
		"weapons": [{
			"name": "Test Gun",
			"type": "hmg",
			"range_km": 1.0,
			"rate_of_fire": 600,
			"vs_soft": 5,
			"vs_armor": 2,
			"platform_accuracy": 1.0,
		}]
	}
	var target_type := {"armor": 0, "concealment": 2}

	# Fire 100 rounds at close range - should get some hits
	var result: Dictionary = c.resolve_combat(
		shooter, target, shooter_type, target_type,
		0, 100, 1, false, false, "O", 0, false, 0, 1.0)

	assert_true(result["hits"] > 0, "100 rounds should score hits")
	assert_true(result["suppression_added"] > 0, "should add suppression")

	# Fire at max range - fewer hits
	var far_result: Dictionary = c.resolve_combat(
		shooter, target, shooter_type, target_type,
		0, 100, 2, false, false, "O", 0, false, 0, 1.0)

	assert_true(far_result["hits"] <= result["hits"], "fewer hits at range")

	# Fire from moving - much fewer hits
	var moving_result: Dictionary = c.resolve_combat(
		shooter, target, shooter_type, target_type,
		0, 100, 1, true, false, "O", 0, false, 0, 1.0)

	assert_true(moving_result["hits"] <= result["hits"], "fewer hits when moving")

	# Woods cover reduces hits
	var cover_result: Dictionary = c.resolve_combat(
		shooter, target, shooter_type, target_type,
		0, 100, 1, false, false, "W", 0, false, 0, 1.0)

	assert_true(cover_result["hits"] <= result["hits"], "fewer hits in woods")

	# Suppression system
	c.apply_suppression("unit1", 50.0)
	assert_range(c.get_suppression("unit1"), 49.0, 51.0, "suppression applied")
	c.decay_suppression(5.0)
	assert_true(c.get_suppression("unit1") < 50.0, "suppression decayed")

	print("  Combat: done")


# ============================================================
# Movement pathfinding tests
# ============================================================
func _test_movement_pathfinding() -> void:
	print("--- Movement pathfinding ---")

	var terrain: Array = []
	var elevation: Array = []
	for r in range(20):
		var trow: Array[String] = []
		var erow: Array[int] = []
		for c in range(20):
			trow.append("O")
			erow.append(5)
		terrain.append(trow)
		elevation.append(erow)

	var terrain_types := {
		"O": {"name": "open", "speed_modifier": 0.5},
		"S": {"name": "street", "speed_modifier": 1.0},
		"W": {"name": "wooded", "speed_modifier": 0.25},
		"R": {"name": "river", "speed_modifier": 0.0},
	}
	var posture_configs := {
		"normal": {"road_preference": 1.5, "cover_preference": 0.5},
		"fast": {"road_preference": 3.0, "cover_preference": 0.0},
		"cautious": {"road_preference": 0.5, "cover_preference": 3.0},
	}

	var grid := HexGrid.new(terrain, elevation, 20, 20, 40.0)
	var units: Array = []
	var unit_types := {}
	var order_mgr := OrderManager.new()
	var clock := GameClock.new()

	var mv := Movement.new(grid, units, unit_types, terrain, terrain_types,
		posture_configs, order_mgr, clock)

	# Basic pathfinding - should make progress toward target
	var from := Vector2i(5, 5)
	var to := Vector2i(10, 5)
	var next: Vector2i = mv.next_step_toward(from, to, "normal")
	assert_true(next != from, "should move from starting position")
	assert_true(grid.hex_distance(next, to) < grid.hex_distance(from, to),
		"should move closer to target")

	# River should be impassable
	for c in range(20):
		terrain[7][c] = "R"
	next = mv.next_step_toward(Vector2i(5, 6), Vector2i(5, 8), "normal")
	# Should try to go sideways or backward, not into river
	if next.y == 7:
		var t: String = terrain[next.y][next.x]
		assert_true(t != "R", "should not step into river")

	print("  Movement: done")


# ============================================================
# YAML Parser tests
# ============================================================
func _test_yaml_parser() -> void:
	print("--- YamlParser ---")

	var simple: Variant = YamlParser.parse("key: value")
	assert_eq(simple["key"], "value", "simple string")

	var num: Variant = YamlParser.parse("count: 42")
	assert_eq(num["count"], 42, "integer value")

	var fl: Variant = YamlParser.parse("rate: 3.14")
	assert_range(float(fl["rate"]), 3.13, 3.15, "float value")

	var bools: Variant = YamlParser.parse("on: true\noff: false")
	assert_eq(bools["on"], true, "true value")
	assert_eq(bools["off"], false, "false value")

	var empty_arr: Variant = YamlParser.parse("items: []")
	assert_true(empty_arr["items"] is Array, "[] parses as Array")

	var nested: Variant = YamlParser.parse("parent:\n  child: hello")
	assert_eq(nested["parent"]["child"], "hello", "nested dict")

	var list: Variant = YamlParser.parse("items:\n  - one\n  - two\n  - three")
	assert_eq(list["items"].size(), 3, "list has 3 items")
	assert_eq(list["items"][0], "one", "first list item")

	print("  YamlParser: done")


# ============================================================
# HQ Comms tests
# ============================================================
func _test_hq_comms() -> void:
	print("--- HQComms ---")

	var terrain: Array = []
	var elevation: Array = []
	for r in range(20):
		var trow: Array[String] = []
		var erow: Array[int] = []
		for c in range(20):
			trow.append("O")
			erow.append(5)
		terrain.append(trow)
		elevation.append(erow)

	var grid := HexGrid.new(terrain, elevation, 20, 20, 40.0)
	var c := Combat.new()
	var om := OrderManager.new()
	var clock := GameClock.new()

	var unit_types := {
		"SHQ": {
			"is_hq": true, "hq_level": 2, "spotting_range": 6,
			"comms": {"name": "Radio", "range_km": 5.0},
			"training": "militia", "morale": 55, "crew": 3,
		},
		"TEC": {
			"spotting_range": 4, "training": "militia", "morale": 50,
		}
	}

	var hq_unit := {
		"name": "HQ", "type_code": "SHQ", "col": 10, "row": 10,
		"side": "player", "unit_status": "", "current_crew": 3,
		"in_comms": false, "in_hq_los": false, "hq_switch_remaining": 0.0,
		"assigned_hq": "",
	}
	var tech := {
		"name": "Tech", "type_code": "TEC", "col": 11, "row": 10,
		"side": "player", "unit_status": "", "current_crew": 4,
		"in_comms": false, "in_hq_los": false, "hq_switch_remaining": 0.0,
		"assigned_hq": "HQ",
	}
	var units: Array = [hq_unit, tech]

	var hq := HQComms.new(grid, units, unit_types, elevation, c, om, clock)
	hq.hq_comms_order_buff = 0.8
	hq.hq_los_order_buff = 0.6
	hq.hq_auto_switch_minutes = 10.0
	# Need spotting range callable
	hq.get_effective_spotting_range = func(u: Dictionary) -> int: return 4

	# Update comms - tech is 1 hex from HQ, within 5km (10 hex) range
	hq.update_hq_comms(0.0)
	assert_true(tech.get("in_comms", false), "tech in comms with nearby HQ")

	# Order modifier when in comms
	var mod: float = hq.get_hq_order_modifier(tech)
	assert_true(mod < 1.0, "order modifier buff when in comms")

	# Move tech out of range
	tech["col"] = 0
	tech["row"] = 0
	hq.update_hq_comms(0.0)
	assert_true(not tech.get("in_comms", false), "tech out of comms when far away")

	print("  HQComms: done")


# ============================================================
# CombatResolver integration tests
# ============================================================
func _test_combat_resolver() -> void:
	print("--- CombatResolver ---")

	var terrain: Array = []
	var elevation: Array = []
	for r in range(20):
		var trow: Array[String] = []
		var erow: Array[int] = []
		for c in range(20):
			trow.append("O")
			erow.append(5)
		terrain.append(trow)
		elevation.append(erow)

	var terrain_types := {
		"O": {"name": "open", "speed_modifier": 0.5},
	}

	var grid := HexGrid.new(terrain, elevation, 20, 20, 40.0)
	var c := Combat.new()
	var om := OrderManager.new()
	var clock := GameClock.new()

	var unit_types := {
		"TEC": {
			"name": "Technical", "training": "militia", "morale": 50,
			"crew": 4, "armor": 0, "concealment": 2, "spotting_range": 4,
			"weapons": [
				{"name": "DShK", "type": "hmg", "range_km": 1.5,
				 "range_moving_km": 0.5, "suppressive_range_km": 2.0,
				 "rate_of_fire": 600, "vs_soft": 8, "vs_armor": 1,
				 "ammo": 500, "platform_accuracy": 0.3},
			],
			"is_hq": false,
		}
	}

	var player := {
		"name": "Player", "type_code": "TEC", "col": 10, "row": 10,
		"side": "player", "unit_status": "",
		"current_crew": 4, "current_morale": 50, "morale_damage": 0,
		"vehicle_damage": 0.0, "mobility_damage": 0.0,
		"current_ammo": [500], "morale_recovery_accum": 0.0,
		"in_comms": false, "in_hq_los": false, "assigned_hq": "",
	}
	var enemy := {
		"name": "Enemy", "type_code": "TEC", "col": 12, "row": 10,
		"side": "enemy", "unit_status": "",
		"current_crew": 4, "current_morale": 50, "morale_damage": 0,
		"vehicle_damage": 0.0, "mobility_damage": 0.0,
		"current_ammo": [500], "morale_recovery_accum": 0.0,
		"in_comms": false, "in_hq_los": false, "assigned_hq": "",
		"default_roe": "fire at will",
	}

	var units: Array = [player, enemy]
	var fire_effects: Array = []
	var death_markers: Dictionary = {}

	var cr := CombatResolver.new(grid, units, unit_types, terrain, elevation,
		terrain_types, c, om, clock)
	cr.fire_effects = fire_effects
	cr.death_markers = death_markers
	cr.MORALE_BREAK_THRESHOLD = 30
	cr.MORALE_ROUT_THRESHOLD = 15
	cr.ROE_RATE_FIRE_AT_WILL = 0.035
	cr.ROE_RATE_RETURN_FIRE = 0.015

	# Test target finding
	var targets: Array = cr.find_targets_in_range(player)
	assert_eq(targets.size(), 1, "finds 1 enemy target")
	assert_eq(targets[0]["name"], "Enemy", "target is enemy")

	# Test effective ROE
	var roe: Order.ROE = cr.get_effective_roe(enemy, null)
	assert_eq(roe, Order.ROE.FIRE_AT_WILL, "enemy default ROE is fire at will")

	# Test ammo morale penalty
	player["current_ammo"] = [500]
	var penalty: int = cr.get_ammo_morale_penalty(player)
	assert_eq(penalty, 0, "full ammo = no penalty")

	player["current_ammo"] = [0]
	penalty = cr.get_ammo_morale_penalty(player)
	assert_true(penalty > 0, "empty ammo = penalty")

	# Test morale check doesn't crash
	player["current_ammo"] = [500]
	player["current_morale"] = 50
	cr.check_morale(player)
	assert_true(true, "check_morale didn't crash")

	# Test recovery
	player["current_morale"] = 30
	cr.recover_morale(player, 5.0)
	# Should not crash, may or may not recover depending on suppression

	print("  CombatResolver: done")
