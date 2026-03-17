class_name UnitPanel
extends CanvasLayer

var panel: PanelContainer
var vbox: VBoxContainer

# Labels
var name_label: Label
var type_label: Label
var speed_label: Label
var crew_label: Label
var training_label: Label
var morale_label: Label
var armor_label: Label
var concealment_label: Label
var spotting_label: Label

# HQ/Command section
var hq_label: Label
var hq_status_label: Label

# Orders section
var order_status_label: Label
var order_mode_label: Label
var order_type_label: Label
var order_timing_label: Label
var order_detail_label: Label
var clear_order_button: Button
var posture_container: HBoxContainer
var posture_buttons: Array[Button] = []
var roe_container: HBoxContainer
var roe_buttons: Array[Button] = []
var pursuit_container: HBoxContainer
var pursuit_buttons: Array[Button] = []
var waypoint_labels: Array[Control] = []

# Stacked unit carousel
var stack_container: HBoxContainer
var stack_left_btn: Button
var stack_label: Label
var stack_right_btn: Button
var stacked_units: Array = []
var stack_index: int = 0

# Weapons section
signal order_cleared(unit_name: String)
signal posture_changed(unit_name: String, posture: Order.Posture)
signal roe_changed(unit_name: String, roe: Order.ROE)
signal pursuit_changed(unit_name: String, pursuit: Order.Pursuit)
signal stack_unit_selected(unit_name: String)

var _current_unit_name: String = ""
var _is_orders_phase: bool = true

var status_label: Label

var weapons_header: Label
var weapons_sep: HSeparator
var weapon_labels: Array[Control] = []


func _init() -> void:
	layer = 10


func _ready() -> void:
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

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
	panel.add_theme_stylebox_override("panel", style)

	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	anchor.offset_left = 6
	anchor.offset_top = -480
	anchor.offset_right = 300
	anchor.offset_bottom = -162
	anchor.grow_horizontal = Control.GROW_DIRECTION_END
	anchor.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(anchor)
	anchor.add_child(panel)
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	# Header
	var header := _make_header("UNIT")
	vbox.add_child(header)
	vbox.add_child(_make_sep())

	name_label = _make_label()
	vbox.add_child(name_label)

	type_label = _make_label()
	vbox.add_child(type_label)

	speed_label = _make_label()
	vbox.add_child(speed_label)

	# Personnel section
	vbox.add_child(_make_sep())
	vbox.add_child(_make_header("PERSONNEL"))
	vbox.add_child(_make_sep())

	crew_label = _make_label()
	vbox.add_child(crew_label)

	training_label = _make_label()
	vbox.add_child(training_label)

	morale_label = _make_label()
	vbox.add_child(morale_label)

	status_label = _make_label()
	vbox.add_child(status_label)

	# Command section
	vbox.add_child(_make_sep())
	vbox.add_child(_make_header("COMMAND"))
	vbox.add_child(_make_sep())

	hq_label = _make_label()
	vbox.add_child(hq_label)
	hq_status_label = _make_detail_label()
	vbox.add_child(hq_status_label)

	# Protection section
	vbox.add_child(_make_sep())
	vbox.add_child(_make_header("PROTECTION"))
	vbox.add_child(_make_sep())

	armor_label = _make_label()
	vbox.add_child(armor_label)

	concealment_label = _make_label()
	vbox.add_child(concealment_label)

	spotting_label = _make_label()
	vbox.add_child(spotting_label)

	# Orders section
	vbox.add_child(_make_sep())
	vbox.add_child(_make_header("ORDERS"))
	vbox.add_child(_make_sep())

	order_status_label = _make_label()
	vbox.add_child(order_status_label)

	order_mode_label = _make_label()
	order_mode_label.add_theme_font_size_override("font_size", 15)
	vbox.add_child(order_mode_label)

	order_type_label = _make_label()
	vbox.add_child(order_type_label)

	# Posture buttons
	posture_container = HBoxContainer.new()
	posture_container.add_theme_constant_override("separation", 4)
	vbox.add_child(posture_container)

	for p in ["FAST", "NORMAL", "CAUTIOUS"]:
		var btn := Button.new()
		btn.text = p
		btn.custom_minimum_size = Vector2(0, 24)
		btn.add_theme_font_size_override("font_size", 11)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var btn_style := StyleBoxFlat.new()
		btn_style.bg_color = Color(0.2, 0.2, 0.25, 0.8)
		btn_style.border_color = Color(0.4, 0.35, 0.5, 0.5)
		btn_style.border_width_top = 1
		btn_style.border_width_left = 1
		btn_style.border_width_right = 1
		btn_style.border_width_bottom = 1
		btn_style.corner_radius_top_left = 2
		btn_style.corner_radius_top_right = 2
		btn_style.corner_radius_bottom_left = 2
		btn_style.corner_radius_bottom_right = 2
		btn.add_theme_stylebox_override("normal", btn_style)

		var btn_hover := btn_style.duplicate()
		btn_hover.bg_color = Color(0.3, 0.25, 0.4, 0.9)
		btn.add_theme_stylebox_override("hover", btn_hover)

		btn.pressed.connect(_on_posture_pressed.bind(p))
		posture_container.add_child(btn)
		posture_buttons.append(btn)

	posture_container.visible = false

	# ROE buttons
	roe_container = HBoxContainer.new()
	roe_container.add_theme_constant_override("separation", 2)
	vbox.add_child(roe_container)

	for r in ["HOLD", "RETURN", "FIRE", "HALT"]:
		var btn := Button.new()
		btn.text = r
		btn.custom_minimum_size = Vector2(0, 24)
		btn.add_theme_font_size_override("font_size", 10)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var btn_style := StyleBoxFlat.new()
		btn_style.bg_color = Color(0.2, 0.2, 0.25, 0.8)
		btn_style.border_color = Color(0.4, 0.35, 0.5, 0.5)
		btn_style.border_width_top = 1
		btn_style.border_width_left = 1
		btn_style.border_width_right = 1
		btn_style.border_width_bottom = 1
		btn_style.corner_radius_top_left = 2
		btn_style.corner_radius_top_right = 2
		btn_style.corner_radius_bottom_left = 2
		btn_style.corner_radius_bottom_right = 2
		btn.add_theme_stylebox_override("normal", btn_style)

		var btn_hover := btn_style.duplicate()
		btn_hover.bg_color = Color(0.3, 0.25, 0.4, 0.9)
		btn.add_theme_stylebox_override("hover", btn_hover)

		btn.pressed.connect(_on_roe_pressed.bind(r))
		roe_container.add_child(btn)
		roe_buttons.append(btn)

	roe_container.visible = false

	# Pursuit buttons
	pursuit_container = HBoxContainer.new()
	pursuit_container.add_theme_constant_override("separation", 4)
	vbox.add_child(pursuit_container)

	for p in ["HOLD", "SHADOW", "PRESS"]:
		var btn := Button.new()
		btn.text = p
		btn.custom_minimum_size = Vector2(0, 24)
		btn.add_theme_font_size_override("font_size", 11)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var btn_style := StyleBoxFlat.new()
		btn_style.bg_color = Color(0.2, 0.2, 0.25, 0.8)
		btn_style.border_color = Color(0.4, 0.35, 0.5, 0.5)
		btn_style.border_width_top = 1
		btn_style.border_width_left = 1
		btn_style.border_width_right = 1
		btn_style.border_width_bottom = 1
		btn_style.corner_radius_top_left = 2
		btn_style.corner_radius_top_right = 2
		btn_style.corner_radius_bottom_left = 2
		btn_style.corner_radius_bottom_right = 2
		btn.add_theme_stylebox_override("normal", btn_style)
		var btn_hover := btn_style.duplicate()
		btn_hover.bg_color = Color(0.3, 0.25, 0.4, 0.9)
		btn.add_theme_stylebox_override("hover", btn_hover)
		btn.pressed.connect(_on_pursuit_pressed.bind(p))
		pursuit_container.add_child(btn)
		pursuit_buttons.append(btn)

	pursuit_container.visible = false

	order_timing_label = _make_detail_label()
	vbox.add_child(order_timing_label)

	order_detail_label = _make_detail_label()
	vbox.add_child(order_detail_label)

	clear_order_button = Button.new()
	clear_order_button.text = "CLEAR ORDERS"
	clear_order_button.custom_minimum_size = Vector2(0, 28)
	clear_order_button.add_theme_font_size_override("font_size", 13)
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.4, 0.15, 0.12, 0.9)
	btn_style.border_color = Color(0.6, 0.25, 0.2)
	btn_style.border_width_top = 1
	btn_style.border_width_left = 1
	btn_style.border_width_right = 1
	btn_style.border_width_bottom = 1
	btn_style.corner_radius_top_left = 2
	btn_style.corner_radius_top_right = 2
	btn_style.corner_radius_bottom_left = 2
	btn_style.corner_radius_bottom_right = 2
	btn_style.content_margin_left = 8.0
	btn_style.content_margin_right = 8.0
	btn_style.content_margin_top = 2.0
	btn_style.content_margin_bottom = 2.0
	clear_order_button.add_theme_stylebox_override("normal", btn_style)
	var btn_hover := btn_style.duplicate()
	btn_hover.bg_color = Color(0.5, 0.2, 0.15, 0.9)
	clear_order_button.add_theme_stylebox_override("hover", btn_hover)
	clear_order_button.pressed.connect(_on_clear_order_pressed)
	vbox.add_child(clear_order_button)

	# Weapons section
	vbox.add_child(_make_sep())
	weapons_header = _make_header("WEAPONS")
	vbox.add_child(weapons_header)
	weapons_sep = _make_sep()
	vbox.add_child(weapons_sep)

	# Stacked unit carousel (shown when multiple units on same hex)
	vbox.add_child(_make_sep())
	stack_container = HBoxContainer.new()
	stack_container.add_theme_constant_override("separation", 4)
	stack_container.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(stack_container)

	stack_left_btn = Button.new()
	stack_left_btn.text = "<"
	stack_left_btn.custom_minimum_size = Vector2(24, 24)
	stack_left_btn.add_theme_font_size_override("font_size", 12)
	var stk_style := StyleBoxFlat.new()
	stk_style.bg_color = Color(0.15, 0.15, 0.15, 0.0)
	stack_left_btn.add_theme_stylebox_override("normal", stk_style)
	stack_left_btn.add_theme_color_override("font_color", Color(0.7, 0.72, 0.65))
	stack_left_btn.pressed.connect(_stack_prev)
	stack_container.add_child(stack_left_btn)

	stack_label = _make_label()
	stack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack_label.custom_minimum_size = Vector2(140, 0)
	stack_container.add_child(stack_label)

	stack_right_btn = Button.new()
	stack_right_btn.text = ">"
	stack_right_btn.custom_minimum_size = Vector2(24, 24)
	stack_right_btn.add_theme_font_size_override("font_size", 12)
	stack_right_btn.add_theme_stylebox_override("normal", stk_style.duplicate())
	stack_right_btn.add_theme_color_override("font_color", Color(0.7, 0.72, 0.65))
	stack_right_btn.pressed.connect(_stack_next)
	stack_container.add_child(stack_right_btn)

	stack_container.visible = false

	panel.visible = false


func set_orders_phase(is_orders: bool) -> void:
	_is_orders_phase = is_orders


func show_unit(unit: Dictionary, utype: Dictionary, order: Order = null, game_time: float = 0.0, suppression_val: float = 0.0) -> void:
	_current_unit_name = unit.get("name", "")
	name_label.text = unit.get("name", "?")
	type_label.text = utype.get("description", utype.get("name", "?"))
	speed_label.text = "Speed:  %d km/h" % utype.get("speed_kmh", 0)

	var max_crew: int = int(utype.get("crew", 0))
	var cur_crew: int = int(unit.get("current_crew", max_crew))
	crew_label.text = "Crew:     %d/%d" % [cur_crew, max_crew]
	if cur_crew < max_crew:
		crew_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.2))
	else:
		crew_label.add_theme_color_override("font_color", Color(0.82, 0.84, 0.78))
	training_label.text = "Training: %s" % str(utype.get("training", "?"))

	# Show current morale (from unit dict) with color coding
	var current_morale: int = int(unit.get("current_morale", utype.get("morale", 0)))
	morale_label.text = "Morale:   %d%%" % current_morale
	if current_morale > 50:
		morale_label.add_theme_color_override("font_color", Color(0.3, 0.85, 0.3))
	elif current_morale >= 30:
		morale_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.2))
	else:
		morale_label.add_theme_color_override("font_color", Color(0.9, 0.25, 0.2))

	# Build status text - show everything relevant
	var status_lines: Array[String] = []
	var status_color := Color(0.82, 0.84, 0.78)

	var unit_status: String = unit.get("unit_status", "")
	if unit_status == "DESTROYED":
		status_lines.append("** DESTROYED **")
		status_color = Color(0.5, 0.1, 0.1)
	elif unit_status == "ROUTING":
		status_lines.append("** ROUTING **")
		status_color = Color(0.95, 0.15, 0.1)
	elif unit_status == "BROKEN":
		status_lines.append("** BROKEN - WITHDRAWING **")
		status_color = Color(0.9, 0.5, 0.1)
	elif unit_status == "IMMOBILISED" or float(unit.get("mobility_damage", 0.0)) >= 1.0:
		status_lines.append("** IMMOBILISED **")
		status_color = Color(0.95, 0.6, 0.1)

	var vdmg: float = float(unit.get("vehicle_damage", 0.0))
	if vdmg > 0.0:
		status_lines.append("Vehicle: %d%% damaged" % int(vdmg * 100))

	var mob_dmg_val: float = float(unit.get("mobility_damage", 0.0))
	if mob_dmg_val > 0.0 and mob_dmg_val < 1.0:
		status_lines.append("Mobility: %d%%" % int((1.0 - mob_dmg_val) * 100))

	if suppression_val > 0.0:
		status_lines.append("Suppression: %d%%" % int(suppression_val))
		if unit_status == "" and suppression_val > 60:
			status_color = Color(0.9, 0.2, 0.1)
		elif unit_status == "" and suppression_val > 30:
			status_color = Color(0.9, 0.6, 0.2)

	if status_lines.size() > 0:
		status_label.text = "\n".join(status_lines)
		status_label.add_theme_color_override("font_color", status_color)
		status_label.visible = true
	else:
		status_label.text = ""
		status_label.visible = false

	# HQ / Command display
	var is_hq: bool = utype.get("is_hq", false)
	var assigned_hq: String = unit.get("assigned_hq", "")
	var in_comms: bool = unit.get("in_comms", false)
	var in_los: bool = unit.get("in_hq_los", false)
	var switching: float = float(unit.get("hq_switch_remaining", 0.0))

	if is_hq:
		var hq_lvl: int = int(utype.get("hq_level", 1))
		if hq_lvl == 1:
			hq_label.text = "Role: Battalion HQ"
		else:
			hq_label.text = "Role: Company HQ"
		hq_label.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
		if assigned_hq != "":
			hq_status_label.text = "Reports to: %s" % assigned_hq
			hq_status_label.visible = true
		else:
			hq_status_label.text = "Top command"
			hq_status_label.visible = true
	elif switching > 0:
		hq_label.text = "Switching HQ..."
		hq_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.2))
		hq_status_label.text = "%.0f min remaining" % switching
		hq_status_label.visible = true
	elif assigned_hq == "":
		hq_label.text = "HQ: Unassigned"
		hq_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.5))
		hq_status_label.visible = false
	elif not in_comms:
		hq_label.text = "OUT OF COMMUNICATIONS"
		hq_label.add_theme_color_override("font_color", Color(0.9, 0.25, 0.2))
		hq_status_label.text = "HQ: %s (out of range)" % assigned_hq
		hq_status_label.visible = true
	elif in_los:
		hq_label.text = "HQ: %s" % assigned_hq
		hq_label.add_theme_color_override("font_color", Color(0.3, 0.85, 0.3))
		hq_status_label.text = "In LOS - full command link"
		hq_status_label.visible = true
	else:
		hq_label.text = "HQ: %s" % assigned_hq
		hq_label.add_theme_color_override("font_color", Color(0.82, 0.84, 0.78))
		hq_status_label.text = "Radio contact"
		hq_status_label.visible = true

	var armor_val: int = utype.get("armor", 0)
	var armor_desc := "none"
	if armor_val >= 7:
		armor_desc = "heavy (%d)" % armor_val
	elif armor_val >= 4:
		armor_desc = "medium (%d)" % armor_val
	elif armor_val >= 1:
		armor_desc = "light (%d)" % armor_val
	armor_label.text = "Armor:    %s" % armor_desc

	concealment_label.text = "Conceal:  %d/10" % utype.get("concealment", 0)

	# Optics and comms
	var optics = utype.get("optics", {})
	if optics is Dictionary and not optics.is_empty():
		var optics_name: String = str(optics.get("name", "Eyesight"))
		var optics_range: float = float(optics.get("range_km", 2.0))
		spotting_label.text = "Optics:   %s (%.1fkm)" % [optics_name, optics_range]
	else:
		spotting_label.text = "Optics:   Eyesight (2.0km)"

	var comms_data = utype.get("comms", {})
	if comms_data is Dictionary and not comms_data.is_empty():
		var comms_name: String = str(comms_data.get("name", "Radio"))
		var comms_range: float = float(comms_data.get("range_km", 0))
		spotting_label.text += "\nComms:    %s (%.0fkm)" % [comms_name, comms_range]

	# Orders section - destroyed units show no orders
	var unit_status_val: String = unit.get("unit_status", "")
	if unit_status_val == "DESTROYED":
		order_status_label.text = "Wreck"
		order_status_label.add_theme_color_override("font_color", Color(0.4, 0.3, 0.25))
		order_mode_label.text = ""
		order_mode_label.visible = false
		order_type_label.visible = false
		order_timing_label.visible = false
		order_detail_label.visible = false
		clear_order_button.visible = false
		posture_container.visible = false
		roe_container.visible = false
		pursuit_container.visible = false
		_clear_waypoint_labels()
	elif order != null:
		var order_color := Color(0.82, 0.84, 0.78)
		match order.status:
			Order.Status.FORMULATING:
				order_color = Color(0.85, 0.6, 0.2)
			Order.Status.PREPARING:
				order_color = Color(0.85, 0.85, 0.2)
			Order.Status.EXECUTING:
				order_color = Color(0.3, 0.85, 0.3)
			Order.Status.COMPLETE:
				order_color = Color(0.5, 0.55, 0.45)
			Order.Status.COUNTERMANDED:
				order_color = Color(0.7, 0.3, 0.3)

		order_status_label.text = "Status:  %s" % order.status_string()
		order_status_label.add_theme_color_override("font_color", order_color)

		# Current mode summary
		var posture_str := Order.posture_to_string(order.posture).to_upper()
		var roe_str := Order.roe_to_string(order.roe).to_upper()
		var pursuit_str := Order.pursuit_to_string(order.pursuit).to_upper()
		order_mode_label.text = "%s  |  %s  |  %s" % [posture_str, roe_str, pursuit_str]
		var mode_color := Color(0.82, 0.84, 0.78)
		match order.posture:
			Order.Posture.FAST: mode_color = Color(0.9, 0.6, 0.3)
			Order.Posture.CAUTIOUS: mode_color = Color(0.5, 0.7, 0.9)
		order_mode_label.add_theme_color_override("font_color", mode_color)
		order_mode_label.visible = true

		order_type_label.text = "Order:   %s" % Order.type_to_string(order.type).to_upper()
		if order.type == Order.Type.ATTACK and order.attack_target != Vector2i(-1, -1):
			order_type_label.text += " -> (%d,%d)" % [order.attack_target.x, order.attack_target.y]
		order_type_label.visible = true

		# Show posture/ROE buttons only if order hasn't started executing and we're in orders phase
		var can_change := _is_orders_phase and \
			order.status != Order.Status.EXECUTING and \
			order.status != Order.Status.COMPLETE
		posture_container.visible = can_change
		roe_container.visible = can_change
		pursuit_container.visible = can_change
		if can_change:
			_highlight_posture_button(order.posture)
			_highlight_roe_button(order.roe)
			_highlight_pursuit_button(order.pursuit)

		var remaining := order.time_until_execution(game_time)
		if remaining > 0:
			order_timing_label.text = "  Ready in: %.0f min" % remaining
			var staff_left := maxf(0.0, (order.issued_at + order.formulation_time) - game_time)
			if staff_left > 0:
				order_detail_label.text = "  Staff: %.0f min  |  Prep: %.0f min" % [
					order.formulation_time, order.preparation_time]
			else:
				order_detail_label.text = "  Unit preparing: %.0f min left" % remaining
		else:
			order_timing_label.text = ""
			order_detail_label.text = ""
		order_timing_label.visible = true
		order_detail_label.visible = true

		if order.was_countermanded:
			order_detail_label.text += "\n  (countermanded - delayed)"

		# Waypoint list
		_clear_waypoint_labels()
		for wi in range(order.waypoints.size()):
			var wp: Dictionary = order.waypoints[wi]
			var wp_hex: Vector2i = wp["hex"]
			var wp_posture: Order.Posture = wp["posture"]
			var wp_roe: Order.ROE = wp.get("roe", Order.ROE.RETURN_FIRE)
			var wp_label := _make_detail_label()
			var marker := ">" if wi == order.current_waypoint_index else " "
			var roe_short := ""
			match wp_roe:
				Order.ROE.HOLD_FIRE: roe_short = "HLD"
				Order.ROE.RETURN_FIRE: roe_short = "RTN"
				Order.ROE.FIRE_AT_WILL: roe_short = "FAW"
				Order.ROE.HALT_AND_ENGAGE: roe_short = "H&E"
			var wp_pursuit: Order.Pursuit = wp.get("pursuit", Order.Pursuit.HOLD)
			var pursuit_short := ""
			if wp_pursuit != Order.Pursuit.HOLD:
				pursuit_short = " " + Order.pursuit_to_string(wp_pursuit).to_upper()
			wp_label.text = " %s %d. (%d,%d) %s %s%s" % [
				marker, wi + 1, wp_hex.x, wp_hex.y,
				Order.posture_to_string(wp_posture).to_upper(),
				roe_short, pursuit_short]
			if wi < order.current_waypoint_index:
				wp_label.add_theme_color_override("font_color", Color(0.4, 0.42, 0.38))
			elif wi == order.current_waypoint_index:
				wp_label.add_theme_color_override("font_color", Color(0.7, 0.3, 0.9))
			vbox.add_child(wp_label)
			# Move above weapons section
			vbox.move_child(wp_label, clear_order_button.get_index())
			waypoint_labels.append(wp_label)

		# Show clear button only during orders phase for non-executing orders
		clear_order_button.visible = _is_orders_phase and \
			order.status != Order.Status.EXECUTING and \
			order.status != Order.Status.COMPLETE
	else:
		order_status_label.text = "Holding position"
		order_status_label.add_theme_color_override("font_color", Color(0.5, 0.55, 0.45))
		var default_roe: String = unit.get("default_roe", "return fire")
		order_mode_label.text = "STATIONARY  |  %s" % default_roe.to_upper()
		order_mode_label.add_theme_color_override("font_color", Color(0.6, 0.62, 0.55))
		order_mode_label.visible = true
		order_type_label.text = ""
		order_type_label.visible = false
		order_timing_label.text = ""
		order_timing_label.visible = false
		order_detail_label.text = ""
		order_detail_label.visible = false
		clear_order_button.visible = false
		posture_container.visible = false
		roe_container.visible = false
		pursuit_container.visible = false
		_clear_waypoint_labels()

	# Clear old weapon labels
	for wl in weapon_labels:
		vbox.remove_child(wl)
		wl.queue_free()
	weapon_labels.clear()

	# Add weapon entries with current ammo
	var weapons = utype.get("weapons", [])
	if not (weapons is Array):
		weapons = []
	var current_ammo: Array = unit.get("current_ammo", [])
	for wi in range(weapons.size()):
		var w: Dictionary = weapons[wi]
		var cur_ammo: int = 0
		if wi < current_ammo.size():
			cur_ammo = int(current_ammo[wi])
		var wblock := _make_weapon_block(w, cur_ammo)
		vbox.add_child(wblock)
		weapon_labels.append(wblock)

	panel.visible = true


func hide_unit() -> void:
	panel.visible = false


func _make_weapon_block(w: Dictionary, cur_ammo: int = -1) -> VBoxContainer:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 1)

	var wname := _make_label()
	wname.text = str(w.get("name", "?"))
	wname.add_theme_color_override("font_color", Color(0.9, 0.85, 0.65))
	block.add_child(wname)

	var range_km: float = w.get("range_km", 0)
	var range_mov: float = w.get("range_moving_km", range_km * 0.3)
	var detail := _make_detail_label()
	detail.text = "  Range: %.1fkm / %.1fkm mov  RoF: %d" % [
		range_km, range_mov, w.get("rate_of_fire", 0)]
	block.add_child(detail)

	var max_ammo: int = int(w.get("ammo", 0))
	var display_ammo: int = cur_ammo if cur_ammo >= 0 else max_ammo
	var effect := _make_detail_label()
	effect.text = "  vs Soft: %d  vs Armor: %d" % [
		w.get("vs_soft", 0), w.get("vs_armor", 0)]
	block.add_child(effect)

	var ammo_label := _make_detail_label()
	ammo_label.text = "  Ammo: %d/%d" % [display_ammo, max_ammo]
	# Color code ammo
	if max_ammo > 0:
		var pct: float = float(display_ammo) / float(max_ammo)
		if display_ammo <= 0:
			ammo_label.add_theme_color_override("font_color", Color(0.9, 0.15, 0.1))
		elif pct < 0.25:
			ammo_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.2))
		elif pct < 0.50:
			ammo_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.2))
		else:
			ammo_label.add_theme_color_override("font_color", Color(0.3, 0.85, 0.3))
	block.add_child(ammo_label)

	return block


func _clear_waypoint_labels() -> void:
	for wl in waypoint_labels:
		vbox.remove_child(wl)
		wl.queue_free()
	waypoint_labels.clear()


func _on_clear_order_pressed() -> void:
	if _current_unit_name != "":
		order_cleared.emit(_current_unit_name)


func set_stacked_units(units_on_hex: Array, current_name: String) -> void:
	stacked_units = units_on_hex
	if stacked_units.size() <= 1:
		stack_container.visible = false
		return
	stack_container.visible = true
	# Find current index
	stack_index = 0
	for i in range(stacked_units.size()):
		if stacked_units[i].get("name", "") == current_name:
			stack_index = i
			break
	_update_stack_label()


func _update_stack_label() -> void:
	if stack_index >= 0 and stack_index < stacked_units.size():
		var u: Dictionary = stacked_units[stack_index]
		stack_label.text = "%s (%d/%d)" % [u.get("name", "?"), stack_index + 1, stacked_units.size()]


func _stack_prev() -> void:
	if stacked_units.is_empty():
		return
	stack_index = (stack_index - 1) % stacked_units.size()
	if stack_index < 0:
		stack_index = stacked_units.size() - 1
	_update_stack_label()
	stack_unit_selected.emit(stacked_units[stack_index].get("name", ""))


func _stack_next() -> void:
	if stacked_units.is_empty():
		return
	stack_index = (stack_index + 1) % stacked_units.size()
	_update_stack_label()
	stack_unit_selected.emit(stacked_units[stack_index].get("name", ""))


func _on_pursuit_pressed(pursuit_name: String) -> void:
	if _current_unit_name == "":
		return
	var p := Order.Pursuit.HOLD
	match pursuit_name:
		"SHADOW": p = Order.Pursuit.SHADOW
		"PRESS": p = Order.Pursuit.PRESS
	_highlight_pursuit_button(p)
	pursuit_changed.emit(_current_unit_name, p)


func _highlight_pursuit_button(p: Order.Pursuit) -> void:
	var active_idx := 0
	match p:
		Order.Pursuit.SHADOW: active_idx = 1
		Order.Pursuit.PRESS: active_idx = 2
	for i in range(pursuit_buttons.size()):
		var btn := pursuit_buttons[i]
		if i == active_idx:
			var active_style := StyleBoxFlat.new()
			active_style.bg_color = Color(0.45, 0.2, 0.6, 0.9)
			active_style.border_color = Color(0.7, 0.3, 0.9)
			active_style.border_width_top = 1
			active_style.border_width_left = 1
			active_style.border_width_right = 1
			active_style.border_width_bottom = 1
			active_style.corner_radius_top_left = 2
			active_style.corner_radius_top_right = 2
			active_style.corner_radius_bottom_left = 2
			active_style.corner_radius_bottom_right = 2
			btn.add_theme_stylebox_override("normal", active_style)
		else:
			var inactive_style := StyleBoxFlat.new()
			inactive_style.bg_color = Color(0.2, 0.2, 0.25, 0.8)
			inactive_style.border_color = Color(0.4, 0.35, 0.5, 0.5)
			inactive_style.border_width_top = 1
			inactive_style.border_width_left = 1
			inactive_style.border_width_right = 1
			inactive_style.border_width_bottom = 1
			inactive_style.corner_radius_top_left = 2
			inactive_style.corner_radius_top_right = 2
			inactive_style.corner_radius_bottom_left = 2
			inactive_style.corner_radius_bottom_right = 2
			btn.add_theme_stylebox_override("normal", inactive_style)


func _on_roe_pressed(roe_name: String) -> void:
	if _current_unit_name == "":
		return
	var r := Order.ROE.RETURN_FIRE
	match roe_name:
		"HOLD": r = Order.ROE.HOLD_FIRE
		"FIRE": r = Order.ROE.FIRE_AT_WILL
		"HALT": r = Order.ROE.HALT_AND_ENGAGE
	_highlight_roe_button(r)
	roe_changed.emit(_current_unit_name, r)


func _highlight_roe_button(r: Order.ROE) -> void:
	var active_idx := 1  # return fire
	match r:
		Order.ROE.HOLD_FIRE: active_idx = 0
		Order.ROE.FIRE_AT_WILL: active_idx = 2
		Order.ROE.HALT_AND_ENGAGE: active_idx = 3

	for i in range(roe_buttons.size()):
		var btn := roe_buttons[i]
		if i == active_idx:
			var active_style := StyleBoxFlat.new()
			active_style.bg_color = Color(0.45, 0.2, 0.6, 0.9)
			active_style.border_color = Color(0.7, 0.3, 0.9)
			active_style.border_width_top = 1
			active_style.border_width_left = 1
			active_style.border_width_right = 1
			active_style.border_width_bottom = 1
			active_style.corner_radius_top_left = 2
			active_style.corner_radius_top_right = 2
			active_style.corner_radius_bottom_left = 2
			active_style.corner_radius_bottom_right = 2
			btn.add_theme_stylebox_override("normal", active_style)
		else:
			var inactive_style := StyleBoxFlat.new()
			inactive_style.bg_color = Color(0.2, 0.2, 0.25, 0.8)
			inactive_style.border_color = Color(0.4, 0.35, 0.5, 0.5)
			inactive_style.border_width_top = 1
			inactive_style.border_width_left = 1
			inactive_style.border_width_right = 1
			inactive_style.border_width_bottom = 1
			inactive_style.corner_radius_top_left = 2
			inactive_style.corner_radius_top_right = 2
			inactive_style.corner_radius_bottom_left = 2
			inactive_style.corner_radius_bottom_right = 2
			btn.add_theme_stylebox_override("normal", inactive_style)


func _on_posture_pressed(posture_name: String) -> void:
	if _current_unit_name == "":
		return
	var posture := Order.Posture.NORMAL
	match posture_name:
		"FAST": posture = Order.Posture.FAST
		"CAUTIOUS": posture = Order.Posture.CAUTIOUS
	_highlight_posture_button(posture)
	posture_changed.emit(_current_unit_name, posture)


func _highlight_posture_button(posture: Order.Posture) -> void:
	var active_idx := 1  # normal
	match posture:
		Order.Posture.FAST: active_idx = 0
		Order.Posture.CAUTIOUS: active_idx = 2

	for i in range(posture_buttons.size()):
		var btn := posture_buttons[i]
		if i == active_idx:
			var active_style := StyleBoxFlat.new()
			active_style.bg_color = Color(0.45, 0.2, 0.6, 0.9)
			active_style.border_color = Color(0.7, 0.3, 0.9)
			active_style.border_width_top = 1
			active_style.border_width_left = 1
			active_style.border_width_right = 1
			active_style.border_width_bottom = 1
			active_style.corner_radius_top_left = 2
			active_style.corner_radius_top_right = 2
			active_style.corner_radius_bottom_left = 2
			active_style.corner_radius_bottom_right = 2
			btn.add_theme_stylebox_override("normal", active_style)
		else:
			var inactive_style := StyleBoxFlat.new()
			inactive_style.bg_color = Color(0.2, 0.2, 0.25, 0.8)
			inactive_style.border_color = Color(0.4, 0.35, 0.5, 0.5)
			inactive_style.border_width_top = 1
			inactive_style.border_width_left = 1
			inactive_style.border_width_right = 1
			inactive_style.border_width_bottom = 1
			inactive_style.corner_radius_top_left = 2
			inactive_style.corner_radius_top_right = 2
			inactive_style.corner_radius_bottom_left = 2
			inactive_style.corner_radius_bottom_right = 2
			btn.add_theme_stylebox_override("normal", inactive_style)


func _make_label() -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.82, 0.84, 0.78))
	return label


func _make_detail_label() -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.6, 0.62, 0.55))
	return label


func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.5, 0.55, 0.45))
	return label


func _make_sep() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Color(0.3, 0.32, 0.25, 0.3))
	return sep
