class_name OrderManager
extends Node

# Config values
var staff_base_minutes: float = 10.0
var staff_training_modifiers: Dictionary = {}
var staff_countermand_penalty: float = 1.5

var unit_prep_base_minutes: float = 5.0
var unit_prep_training_modifiers: Dictionary = {}
var unit_prep_order_modifiers: Dictionary = {}

# Active orders per unit (keyed by unit name)
var active_orders: Dictionary = {}  # String -> Order

# Order history for display
var order_log: Array[String] = []


func _ready() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/game.yaml")

	staff_base_minutes = cfg.get_float("staff_formulation.base_minutes", 10.0)
	var staff_mods = cfg.get_value("staff_formulation.training_modifier", {})
	for key in staff_mods:
		staff_training_modifiers[key] = float(staff_mods[key])
	staff_countermand_penalty = cfg.get_float("staff_formulation.countermand_penalty", 1.5)

	unit_prep_base_minutes = cfg.get_float("unit_preparation.base_minutes", 5.0)
	var prep_mods = cfg.get_value("unit_preparation.training_modifier", {})
	for key in prep_mods:
		unit_prep_training_modifiers[key] = float(prep_mods[key])
	var order_mods = cfg.get_value("unit_preparation.order_modifier", {})
	for key in order_mods:
		unit_prep_order_modifiers[key] = float(order_mods[key])


func issue_order(unit: Dictionary, unit_type: Dictionary, order_type: Order.Type,
		target: Vector2i, current_time: float, posture: Order.Posture = Order.Posture.NORMAL,
		roe: Order.ROE = Order.ROE.RETURN_FIRE, hq_modifier: float = 1.0,
		pursuit: Order.Pursuit = Order.Pursuit.HOLD) -> Order:
	var unit_name: String = unit.get("name", "?")
	var training: String = str(unit_type.get("training", "regular"))

	# Check if there's an existing order we can add a waypoint to
	if unit_name in active_orders:
		var existing: Order = active_orders[unit_name]
		if existing.status == Order.Status.FORMULATING or \
				existing.status == Order.Status.PREPARING:
			# Add waypoint to existing order
			existing.add_waypoint(target, posture, roe, pursuit)
			_log("%s: waypoint %d added (%s)" % [
				unit_name, existing.waypoint_count(),
				Order.posture_to_string(posture).to_upper()])
			return existing

	# Countermand if executing
	var countermanding := false
	if unit_name in active_orders:
		var existing: Order = active_orders[unit_name]
		if existing.status == Order.Status.EXECUTING:
			countermanding = true
			existing.status = Order.Status.COUNTERMANDED
			_log("Order countermanded: %s" % unit_name)

	var order := Order.new()
	order.type = order_type
	order.add_waypoint(target, posture, roe, pursuit)
	order.unit_name = unit_name
	order.issued_at = current_time
	order.was_countermanded = countermanding

	# Calculate staff formulation time
	var staff_mod: float = staff_training_modifiers.get(training, 1.0)
	order.formulation_time = staff_base_minutes * staff_mod * hq_modifier
	if countermanding:
		order.formulation_time *= staff_countermand_penalty

	# Calculate unit preparation time
	var prep_mod: float = unit_prep_training_modifiers.get(training, 1.0)
	var order_type_str := Order.type_to_string(order_type)
	var order_mod: float = unit_prep_order_modifiers.get(order_type_str, 1.0)
	order.preparation_time = unit_prep_base_minutes * prep_mod * order_mod * hq_modifier

	active_orders[unit_name] = order

	var total := order.total_delay()
	_log("%s: %s order issued (ready in %.0f min)" % [
		unit_name, order_type_str.to_upper(), total])

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


func _log(msg: String) -> void:
	order_log.append(msg)
	if order_log.size() > 50:
		order_log.remove_at(0)
