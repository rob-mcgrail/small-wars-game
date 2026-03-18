extends SceneTree

## C2 delay calculator - shows order delay times for various situations.
## Run with: godot --headless --script tests/test_c2_delays.gd

func _init() -> void:
	print("=" .repeat(70))
	print("C2 ORDER DELAY SCENARIOS")
	print("=" .repeat(70))

	# Load faction configs
	var hzb_cfg := Config.new()
	hzb_cfg.load_file("res://conflicts/southern_lebanon_2006/factions/hezbollah.yaml")
	var hzb_c2: Dictionary = hzb_cfg.get_value("c2", {})

	var idf_cfg := Config.new()
	idf_cfg.load_file("res://conflicts/southern_lebanon_2006/factions/idf.yaml")
	var idf_c2: Dictionary = idf_cfg.get_value("c2", {})

	print("\n--- HEZBOLLAH C2 CONFIG ---")
	print("  TX base: %.0f min | Planning base: %.0f min" % [
		float(hzb_c2.get("hq_transmission_base", 0)),
		float(hzb_c2.get("planning_base", 0))])
	print("  Initiative: %.0f%% | Runners: %s | LOS TX: %.1f min" % [
		float(hzb_c2.get("isolated_initiative", 0)) * 100,
		str(hzb_c2.get("can_use_runners", false)),
		float(hzb_c2.get("los_transmission_time", 0))])

	print("\n--- IDF C2 CONFIG ---")
	print("  TX base: %.0f min | Planning base: %.0f min" % [
		float(idf_c2.get("hq_transmission_base", 0)),
		float(idf_c2.get("planning_base", 0))])
	print("  Initiative: %.0f%% | Runners: %s | LOS TX: %.1f min" % [
		float(idf_c2.get("isolated_initiative", 0)) * 100,
		str(idf_c2.get("can_use_runners", false)),
		float(idf_c2.get("los_transmission_time", 0))])

	print("\n" + "=" .repeat(70))
	print("HEZBOLLAH SCENARIOS")
	print("=" .repeat(70))

	_print_scenario("Kornet team, LOS to HQ, chain intact, MOVE order",
		hzb_c2, "move", true, true, false, false, true, 2)
	_print_scenario("Kornet team, LOS to HQ, chain intact, AMBUSH order",
		hzb_c2, "ambush", true, true, false, false, true, 2)
	_print_scenario("Kornet team, LOS to HQ, chain intact, ATTACK order",
		hzb_c2, "attack", true, true, false, false, true, 2)
	_print_scenario("Kornet team, radio to HQ, chain intact, MOVE order",
		hzb_c2, "move", true, false, false, false, true, 5)
	_print_scenario("Kornet team, radio to HQ, chain intact, AMBUSH order",
		hzb_c2, "ambush", true, false, false, false, true, 5)
	_print_scenario("Kornet team, radio to HQ, HQ suppressed, MOVE order",
		hzb_c2, "move", true, false, true, false, true, 5)
	_print_scenario("Kornet team, radio to HQ, HQ moving, MOVE order",
		hzb_c2, "move", true, false, false, true, true, 5)
	_print_scenario("Kornet team, radio to HQ, HQ suppressed + moving, MOVE",
		hzb_c2, "move", true, false, true, true, true, 5)
	_print_scenario("Kornet team, radio to HQ, chain BROKEN, MOVE order",
		hzb_c2, "move", true, false, false, false, false, 5)
	_print_scenario("Fighter squad, isolated, initiative SUCCESS, MOVE",
		hzb_c2, "move", false, false, false, false, false, 10, true)
	_print_scenario("Fighter squad, isolated, runner (10 hexes), MOVE",
		hzb_c2, "move", false, false, false, false, false, 10, false)
	_print_scenario("Fighter squad, isolated, runner (20 hexes), MOVE",
		hzb_c2, "move", false, false, false, false, false, 20, false)
	_print_scenario("Technical, LOS to HQ, PATROL order",
		hzb_c2, "patrol", true, true, false, false, true, 2)
	_print_scenario("Technical, radio, chain intact, WITHDRAW order",
		hzb_c2, "withdraw", true, false, false, false, true, 5)
	_print_scenario("Technical, radio, MOVE order (warm start)",
		hzb_c2, "move", true, false, false, false, true, 5, false, true)
	_print_scenario("Technical, radio, MOVE order (countermand)",
		hzb_c2, "move", true, false, false, false, true, 5, false, false, true)

	print("\n" + "=" .repeat(70))
	print("IDF SCENARIOS")
	print("=" .repeat(70))

	_print_scenario("Merkava, LOS to HQ, chain intact, MOVE order",
		idf_c2, "move", true, true, false, false, true, 2)
	_print_scenario("Merkava, LOS to HQ, chain intact, ATTACK order",
		idf_c2, "attack", true, true, false, false, true, 2)
	_print_scenario("Merkava, radio to HQ, chain intact, MOVE order",
		idf_c2, "move", true, false, false, false, true, 5)
	_print_scenario("Merkava, radio to HQ, chain intact, ATTACK order",
		idf_c2, "attack", true, false, false, false, true, 5)
	_print_scenario("Merkava, radio to HQ, HQ suppressed, MOVE order",
		idf_c2, "move", true, false, true, false, true, 5)
	_print_scenario("Merkava, radio to HQ, HQ suppressed + moving, MOVE",
		idf_c2, "move", true, false, true, true, true, 5)
	_print_scenario("Merkava, radio to HQ, chain BROKEN, MOVE order",
		idf_c2, "move", true, false, false, false, false, 5)
	_print_scenario("IDF Infantry, isolated, initiative SUCCESS, MOVE",
		idf_c2, "move", false, false, false, false, false, 10, true)
	_print_scenario("IDF Infantry, isolated, no runners, LOCKOUT",
		idf_c2, "move", false, false, false, false, false, 10, false)
	_print_scenario("IDF Infantry, isolated, no runners, low morale (25)",
		idf_c2, "move", false, false, false, false, false, 10, false, false, false, 25)
	_print_scenario("Merkava, radio, MOVE (warm start)",
		idf_c2, "move", true, false, false, false, true, 5, false, true)
	_print_scenario("Merkava, radio, MOVE (countermand)",
		idf_c2, "move", true, false, false, false, true, 5, false, false, true)
	_print_scenario("Namer APC, radio, chain intact, MOVE order",
		idf_c2, "move", true, false, false, false, true, 8)
	_print_scenario("IDF HQ unit, self-order, MOVE",
		idf_c2, "move", true, true, false, false, true, 0, false, false, false, 65, true)

	print("\n" + "=" .repeat(70))
	print("COMPARISON: Same situation, both factions")
	print("=" .repeat(70))

	print("\n  Radio to HQ, chain intact, MOVE:")
	var h := _calc(hzb_c2, "move", true, false, false, false, true, 5)
	var i := _calc(idf_c2, "move", true, false, false, false, true, 5)
	print("    Hezbollah: TX %.1f + Plan %.1f = %.1f min" % [h[0], h[1], h[0] + h[1]])
	print("    IDF:       TX %.1f + Plan %.1f = %.1f min" % [i[0], i[1], i[0] + i[1]])

	print("\n  Radio to HQ, HQ suppressed, ATTACK:")
	h = _calc(hzb_c2, "attack", true, false, true, false, true, 5)
	i = _calc(idf_c2, "attack", true, false, true, false, true, 5)
	print("    Hezbollah: TX %.1f + Plan %.1f = %.1f min" % [h[0], h[1], h[0] + h[1]])
	print("    IDF:       TX %.1f + Plan %.1f = %.1f min" % [i[0], i[1], i[0] + i[1]])

	print("\n  Isolated, MOVE:")
	h = _calc(hzb_c2, "move", false, false, false, false, false, 10, true)
	i = _calc(idf_c2, "move", false, false, false, false, false, 10, true)
	var h_run := _calc(hzb_c2, "move", false, false, false, false, false, 10, false)
	var i_lock := _calc(idf_c2, "move", false, false, false, false, false, 10, false)
	print("    Hezbollah (initiative): TX %.1f + Plan %.1f = %.1f min" % [h[0], h[1], h[0] + h[1]])
	print("    Hezbollah (runner 10h): TX %.1f + Plan %.1f = %.1f min" % [h_run[0], h_run[1], h_run[0] + h_run[1]])
	print("    IDF (initiative):       TX %.1f + Plan %.1f = %.1f min" % [i[0], i[1], i[0] + i[1]])
	print("    IDF (lockout):          TX %.1f + Plan %.1f = %.1f min" % [i_lock[0], i_lock[1], i_lock[0] + i_lock[1]])

	print("")
	quit(0)


func _print_scenario(desc: String, c2: Dictionary, order_type: String,
		in_comms: bool, in_los: bool, hq_suppressed: bool, hq_mobile: bool,
		chain_intact: bool, dist_to_hq: int,
		initiative_success: bool = false, warm_start: bool = false,
		countermand: bool = false, morale: int = 50, is_hq: bool = false) -> void:

	var r := _calc(c2, order_type, in_comms, in_los, hq_suppressed, hq_mobile,
		chain_intact, dist_to_hq, initiative_success, warm_start, countermand, morale, is_hq)
	var tx: float = r[0]
	var plan: float = r[1]
	print("\n  %s" % desc)
	print("    TX: %5.1f min | Plan: %5.1f min | Total: %5.1f min" % [tx, plan, tx + plan])


func _calc(c2: Dictionary, order_type: String,
		in_comms: bool, in_los: bool, hq_suppressed: bool, hq_mobile: bool,
		chain_intact: bool, dist_to_hq: int,
		initiative_success: bool = false, warm_start: bool = false,
		countermand: bool = false, morale: int = 50, is_hq: bool = false) -> Array:

	# Transmission
	var tx: float = 0.0
	if is_hq:
		tx = 0.5
	elif in_los:
		tx = float(c2.get("los_transmission_time", 0.5))
	elif in_comms:
		tx = float(c2.get("hq_transmission_base", 5))
		if hq_suppressed:
			tx *= float(c2.get("hq_suppressed_multiplier", 3.0))
		if hq_mobile:
			tx *= float(c2.get("hq_mobile_multiplier", 1.5))
		if chain_intact:
			tx *= float(c2.get("chain_intact_multiplier", 0.7))
	else:
		if initiative_success:
			tx = 2.0
		elif c2.get("can_use_runners", false):
			tx = float(dist_to_hq) * float(c2.get("runner_minutes_per_hex", 4))
		else:
			tx = float(c2.get("isolated_lockout_minutes", 15))
			if morale < 30:
				tx *= 2.0
			elif morale < 50:
				tx *= 1.5

	# Planning
	var planning_mults: Dictionary = c2.get("planning_multiplier", {})
	var type_mult: float = 1.0
	if planning_mults is Dictionary:
		type_mult = float(planning_mults.get(order_type, 1.0))
	var plan: float = float(c2.get("planning_base", 3)) * type_mult
	if in_los:
		plan *= float(c2.get("planning_los_multiplier", 0.6))
	if chain_intact:
		plan *= float(c2.get("planning_chain_multiplier", 0.8))

	# Warm start / countermand
	if countermand:
		var cm: float = float(c2.get("countermand_multiplier", 1.5))
		tx *= cm
		plan *= cm
	elif warm_start:
		var ws: float = float(c2.get("warm_start_multiplier", 0.4))
		tx *= ws
		plan *= ws

	return [tx, plan]
