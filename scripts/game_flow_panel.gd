class_name GameFlowPanel
extends CanvasLayer

signal auto_continue_changed(mode: String)

var panel: PanelContainer
var time_label: Label
var daynight_label: Label
var phase_label: Label
var next_orders_label: Label
var cycle_label: Label
var action_button: Button
var continue_complete_cb: CheckBox
var continue_engaged_cb: CheckBox
var ooda_cycles_passed: int = 0
var can_interrupt: bool = false

var game_clock: GameClock
var sunrise: int = 6
var sunset: int = 19


func _init() -> void:
	layer = 10


func _ready() -> void:
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(240, 0)
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

	# Anchor top-center
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_TOP)
	anchor.offset_left = -120
	anchor.offset_top = 6
	anchor.offset_right = 120
	anchor.offset_bottom = 200
	add_child(anchor)
	anchor.add_child(panel)
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Time display - big and prominent
	time_label = Label.new()
	time_label.add_theme_font_size_override("font_size", 32)
	time_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.82))
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_label.text = "06:00"
	vbox.add_child(time_label)

	# Day/night indicator
	daynight_label = Label.new()
	daynight_label.add_theme_font_size_override("font_size", 13)
	daynight_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	daynight_label.text = ""
	vbox.add_child(daynight_label)

	# Phase indicator
	phase_label = Label.new()
	phase_label.add_theme_font_size_override("font_size", 14)
	phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phase_label.text = "ORDERS"
	vbox.add_child(phase_label)

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Color(0.3, 0.32, 0.25, 0.3))
	vbox.add_child(sep)

	# OODA cycle info
	cycle_label = Label.new()
	cycle_label.add_theme_font_size_override("font_size", 13)
	cycle_label.add_theme_color_override("font_color", Color(0.55, 0.58, 0.5))
	cycle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cycle_label.text = "OODA cycle: 15 min"
	cycle_label.mouse_filter = Control.MOUSE_FILTER_STOP
	vbox.add_child(cycle_label)

	# Next orders phase
	next_orders_label = Label.new()
	next_orders_label.add_theme_font_size_override("font_size", 13)
	next_orders_label.add_theme_color_override("font_color", Color(0.55, 0.58, 0.5))
	next_orders_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	next_orders_label.text = ""
	vbox.add_child(next_orders_label)

	# Action button
	action_button = Button.new()
	action_button.text = "EXECUTE ORDERS"
	action_button.custom_minimum_size = Vector2(0, 36)
	action_button.add_theme_font_size_override("font_size", 14)

	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.25, 0.35, 0.2, 0.9)
	btn_style.border_color = Color(0.4, 0.55, 0.3)
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
	btn_style.content_margin_top = 4.0
	btn_style.content_margin_bottom = 4.0
	action_button.add_theme_stylebox_override("normal", btn_style)

	var btn_hover := btn_style.duplicate()
	btn_hover.bg_color = Color(0.3, 0.42, 0.25, 0.9)
	action_button.add_theme_stylebox_override("hover", btn_hover)

	var btn_pressed := btn_style.duplicate()
	btn_pressed.bg_color = Color(0.2, 0.28, 0.15, 0.9)
	action_button.add_theme_stylebox_override("pressed", btn_pressed)

	var btn_disabled := btn_style.duplicate()
	btn_disabled.bg_color = Color(0.15, 0.15, 0.15, 0.7)
	btn_disabled.border_color = Color(0.25, 0.25, 0.25, 0.4)
	action_button.add_theme_stylebox_override("disabled", btn_disabled)
	action_button.add_theme_color_override("font_disabled_color", Color(0.4, 0.4, 0.4))

	action_button.pressed.connect(_on_action_pressed)
	vbox.add_child(action_button)

	# Auto-continue checkboxes
	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("separator", Color(0.3, 0.32, 0.25, 0.3))
	vbox.add_child(sep2)

	continue_complete_cb = CheckBox.new()
	continue_complete_cb.text = "Progress until need orders"
	continue_complete_cb.button_pressed = true
	continue_complete_cb.add_theme_font_size_override("font_size", 12)
	continue_complete_cb.add_theme_color_override("font_color", Color(0.7, 0.72, 0.65))
	vbox.add_child(continue_complete_cb)

	continue_engaged_cb = CheckBox.new()
	continue_engaged_cb.text = "Progress until engaged"
	continue_engaged_cb.button_pressed = true
	continue_engaged_cb.add_theme_font_size_override("font_size", 12)
	continue_engaged_cb.add_theme_color_override("font_color", Color(0.7, 0.72, 0.65))
	vbox.add_child(continue_engaged_cb)


func is_progress_until_orders() -> bool:
	return continue_complete_cb.button_pressed


func is_progress_until_engaged() -> bool:
	return continue_engaged_cb.button_pressed


func set_clock(clock: GameClock) -> void:
	game_clock = clock
	game_clock.phase_changed.connect(_on_phase_changed)
	cycle_label.text = "OODA cycle: %d min" % int(game_clock.ooda_cycle_minutes)


func _process(_delta: float) -> void:
	if game_clock == null:
		return

	time_label.text = game_clock.get_time_string()

	# Day/night indicator
	var hour: int = (int(game_clock.game_time_minutes) / 60) % 24
	if hour < sunrise or hour >= sunset:
		daynight_label.text = "NIGHT"
		daynight_label.add_theme_color_override("font_color", Color(0.4, 0.45, 0.7))
	else:
		daynight_label.text = "DAY"
		daynight_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))

	if game_clock.is_orders_phase():
		next_orders_label.text = ""
	else:
		var mins := game_clock.get_minutes_until_orders()
		next_orders_label.text = "Next orders in: %d min" % ceili(mins)


func _on_phase_changed(phase: String) -> void:
	phase_label.text = phase
	if phase == "ORDERS":
		phase_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.3))
	else:
		phase_label.add_theme_color_override("font_color", Color(0.85, 0.65, 0.2))
	_update_button_state()


func set_interruptable() -> void:
	can_interrupt = true
	_update_button_state()


func reset_ooda_count() -> void:
	ooda_cycles_passed = 0
	can_interrupt = false
	_update_button_state()


func _update_button_state() -> void:
	if game_clock == null:
		return
	if game_clock.is_orders_phase():
		# Green: EXECUTE ORDERS
		action_button.text = "EXECUTE ORDERS"
		action_button.disabled = false
		can_interrupt = false
		_set_button_style_green()
	elif can_interrupt:
		# Orange: INTERRUPT WITH ORDERS
		action_button.text = "INTERRUPT WITH ORDERS"
		action_button.disabled = false
		_set_button_style_orange()
	else:
		# Grey: EXECUTING
		action_button.text = "EXECUTING..."
		action_button.disabled = true
		_set_button_style_disabled()


func _set_button_style_green() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.25, 0.35, 0.2, 0.9)
	s.border_color = Color(0.4, 0.55, 0.3)
	s.border_width_top = 1; s.border_width_left = 1
	s.border_width_right = 1; s.border_width_bottom = 1
	s.corner_radius_top_left = 2; s.corner_radius_top_right = 2
	s.corner_radius_bottom_left = 2; s.corner_radius_bottom_right = 2
	s.content_margin_left = 8.0; s.content_margin_right = 8.0
	s.content_margin_top = 4.0; s.content_margin_bottom = 4.0
	action_button.add_theme_stylebox_override("normal", s)
	action_button.add_theme_color_override("font_color", Color(0.9, 0.95, 0.85))


func _set_button_style_orange() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.45, 0.3, 0.1, 0.9)
	s.border_color = Color(0.7, 0.5, 0.2)
	s.border_width_top = 1; s.border_width_left = 1
	s.border_width_right = 1; s.border_width_bottom = 1
	s.corner_radius_top_left = 2; s.corner_radius_top_right = 2
	s.corner_radius_bottom_left = 2; s.corner_radius_bottom_right = 2
	s.content_margin_left = 8.0; s.content_margin_right = 8.0
	s.content_margin_top = 4.0; s.content_margin_bottom = 4.0
	action_button.add_theme_stylebox_override("normal", s)
	action_button.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	var h := s.duplicate()
	h.bg_color = Color(0.55, 0.35, 0.12, 0.9)
	action_button.add_theme_stylebox_override("hover", h)


func _set_button_style_disabled() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.15, 0.15, 0.15, 0.7)
	s.border_color = Color(0.25, 0.25, 0.25, 0.4)
	s.border_width_top = 1; s.border_width_left = 1
	s.border_width_right = 1; s.border_width_bottom = 1
	s.corner_radius_top_left = 2; s.corner_radius_top_right = 2
	s.corner_radius_bottom_left = 2; s.corner_radius_bottom_right = 2
	s.content_margin_left = 8.0; s.content_margin_right = 8.0
	s.content_margin_top = 4.0; s.content_margin_bottom = 4.0
	action_button.add_theme_stylebox_override("normal", s)


signal execute_pressed()
signal interrupt_pressed()


func _on_action_pressed() -> void:
	if can_interrupt:
		interrupt_pressed.emit()
	elif game_clock and game_clock.is_orders_phase():
		execute_pressed.emit()
