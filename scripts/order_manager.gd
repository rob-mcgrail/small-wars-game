class_name OrderManager
extends Node

## Manages orders for all units. Calculates transmission and planning delays
## based on faction C2 configuration, HQ state, and unit situation.

# Active orders per unit (keyed by unit name)
var active_orders: Dictionary = {}  # String -> Order

# Order history for display
var order_log: Array[String] = []

# Default C2 config (overridden per-faction via scenario)
var default_c2: Dictionary = {
	"hq_transmission_base": 5,
	"hq_suppressed_multiplier": 3.0,
	"hq_mobile_multiplier": 1.5,
	"chain_intact_multiplier": 0.7,
	"los_transmission_time": 0.5,
	"planning_base": 3,
	"planning_multiplier": {},
	"planning_los_multiplier": 0.6,
	"planning_chain_multiplier": 0.8,
	"isolated_initiative": 0.3,
	"can_use_runners": false,
	"runner_minutes_per_hex": 4,
	"isolated_lockout_minutes": 15,
	"warm_start_multiplier": 0.4,
	"countermand_multiplier": 1.5,
}

# Per-side C2 configs (set by scenario loader via hex_map)
var player_c2: Dictionary = {}
var enemy_c2: Dictionary = {}


func get_c2(side: String) -> Dictionary:
	if side == "player" and not player_c2.is_empty():
		return player_c2
	if side == "enemy" and not enemy_c2.is_empty():
		return enemy_c2
	return default_c2


func issue_order(unit: Dictionary, unit_type: Dictionary, order_type: Order.Type,
		target: Vector2i, current_time: float, posture: Order.Posture = Order.Posture.NORMAL,
		roe: Order.ROE = Order.ROE.RETURN_FIRE,
		pursuit: Order.Pursuit = Order.Pursuit.HOLD,
		c2_context: Dictionary = {}) -> Order:
	## Issue an order. c2_context should contain:
	##   in_comms: bool, in_hq_los: bool, hq_suppressed: bool, hq_mobile: bool,
	##   chain_intact: bool, distance_to_hq: int, side: String

	var unit_name: String = unit.get("name", "?")
	var side: String = c2_context.get("side", unit.get("side", "player"))
	var c2: Dictionary = get_c2(side)

	# Check if there's an existing order we can add a waypoint to
	if unit_name in active_orders:
		var existing: Order = active_orders[unit_name]
		if existing.status == Order.Status.FORMULATING or \
				existing.status == Order.Status.PREPARING:
			existing.add_waypoint(target, posture, roe, pursuit)
			_log("%s: waypoint %d added (%s)" % [
				unit_name, existing.waypoint_count(),
				Order.posture_to_string(posture).to_upper()])
			return existing

	# Check for warm start or countermand
	var countermanding := false
	var warm_start := false
	if unit_name in active_orders:
		var existing: Order = active_orders[unit_name]
		if existing.status == Order.Status.EXECUTING:
			countermanding = true
			existing.status = Order.Status.COUNTERMANDED
			_log("Order countermanded: %s" % unit_name)
		elif existing.status == Order.Status.COMPLETE:
			if existing.type == order_type:
				warm_start = true

	var order := Order.new()
	order.type = order_type
	order.add_waypoint(target, posture, roe, pursuit)
	order.unit_name = unit_name
	order.issued_at = current_time
	order.was_countermanded = countermanding

	# === TRANSMISSION TIME ===
	var in_comms: bool = c2_context.get("in_comms", false)
	var in_hq_los: bool = c2_context.get("in_hq_los", false)
	var hq_suppressed: bool = c2_context.get("hq_suppressed", false)
	var hq_mobile: bool = c2_context.get("hq_mobile", false)
	var chain_intact: bool = c2_context.get("chain_intact", false)
	var distance_to_hq: int = c2_context.get("distance_to_hq", 999)
	var is_hq: bool = unit_type.get("is_hq", false)

	var transmission: float = 0.0

	if is_hq:
		# HQ units can self-order with minimal delay
		transmission = 0.5
	elif in_hq_los:
		# Direct LOS to HQ - near instant (shouting distance, hand signals)
		transmission = float(c2.get("los_transmission_time", 0.5))
	elif in_comms:
		# Within radio range of HQ
		transmission = float(c2.get("hq_transmission_base", 5))
		if hq_suppressed:
			transmission *= float(c2.get("hq_suppressed_multiplier", 3.0))
		if hq_mobile:
			transmission *= float(c2.get("hq_mobile_multiplier", 1.5))
		if chain_intact:
			transmission *= float(c2.get("chain_intact_multiplier", 0.7))
	else:
		# Isolated - no HQ contact
		var initiative: float = float(c2.get("isolated_initiative", 0.3))
		if randf() < initiative:
			# Unit shows initiative - acts on order quickly
			transmission = 2.0
			_log("%s: using initiative (isolated)" % unit_name)
		elif c2.get("can_use_runners", false):
			# Send a runner to nearest HQ
			transmission = float(distance_to_hq) * float(c2.get("runner_minutes_per_hex", 4))
			_log("%s: sending runner to HQ (%d hexes, %.0f min)" % [
				unit_name, distance_to_hq, transmission])
		else:
			# Locked out - can't receive complex orders
			transmission = float(c2.get("isolated_lockout_minutes", 15))
			# Low morale increases lockout
			var cur_morale: int = int(unit.get("current_morale", 50))
			if cur_morale < 30:
				transmission *= 2.0
			elif cur_morale < 50:
				transmission *= 1.5
			_log("%s: isolated, no runners (%.0f min lockout)" % [unit_name, transmission])

	order.formulation_time = transmission

	# === PLANNING TIME ===
	var order_type_str := Order.type_to_string(order_type)
	var planning_mults: Dictionary = c2.get("planning_multiplier", {})
	var type_mult: float = 1.0
	if planning_mults is Dictionary:
		type_mult = float(planning_mults.get(order_type_str, 1.0))

	var planning: float = float(c2.get("planning_base", 3)) * type_mult

	if in_hq_los:
		planning *= float(c2.get("planning_los_multiplier", 0.6))
	if chain_intact:
		planning *= float(c2.get("planning_chain_multiplier", 0.8))

	# Warm start / countermand modifiers
	if countermanding:
		planning *= float(c2.get("countermand_multiplier", 1.5))
		transmission *= float(c2.get("countermand_multiplier", 1.5))
		order.formulation_time = transmission
	elif warm_start:
		var ws: float = float(c2.get("warm_start_multiplier", 0.4))
		planning *= ws
		order.formulation_time *= ws

	order.preparation_time = planning

	active_orders[unit_name] = order

	var total := order.total_delay()
	_log("%s: %s order (tx: %.1f min, plan: %.1f min, total: %.1f min)" % [
		unit_name, order_type_str.to_upper(), order.formulation_time,
		order.preparation_time, total])

	return order


func remove_last_waypoint(unit_name: String) -> bool:
	if unit_name not in active_orders:
		return false
	var order: Order = active_orders[unit_name]
	if order.status == Order.Status.EXECUTING or \
			order.status == Order.Status.COMPLETE:
		return false
	var removed := order.remove_last_waypoint()
	if removed:
		if order.is_empty():
			active_orders.erase(unit_name)
			_log("%s: all waypoints removed, order cancelled" % unit_name)
		else:
			_log("%s: last waypoint removed (%d remaining)" % [unit_name, order.waypoint_count()])
	return removed


func cancel_order(unit_name: String) -> void:
	if unit_name in active_orders:
		var order: Order = active_orders[unit_name]
		order.status = Order.Status.COUNTERMANDED
		active_orders.erase(unit_name)
		_log("%s: order cancelled" % unit_name)


func update_orders(current_time: float) -> void:
	for unit_name in active_orders:
		var order: Order = active_orders[unit_name]
		if order.status != Order.Status.COMPLETE and order.status != Order.Status.COUNTERMANDED:
			var old_status := order.status
			order.update(current_time)
			if order.status != old_status:
				_log("%s: order now %s" % [unit_name, order.status_string()])


func get_order(unit_name: String) -> Order:
	if unit_name in active_orders:
		return active_orders[unit_name]
	return null


func issue_immediate_order(unit: Dictionary, order_type: Order.Type, target: Vector2i,
		posture: Order.Posture, roe: Order.ROE, game_time: float) -> void:
	## Creates an order that skips delays (for break/rout/pursuit auto-orders).
	var order := Order.new()
	order.type = order_type
	order.add_waypoint(target, posture, roe)
	order.unit_name = unit.get("name", "")
	order.issued_at = game_time
	order.formulation_time = 0.0
	order.preparation_time = 0.0
	order.status = Order.Status.EXECUTING
	active_orders[unit.get("name", "")] = order


func _log(msg: String) -> void:
	order_log.append(msg)
	if order_log.size() > 50:
		order_log.remove_at(0)
