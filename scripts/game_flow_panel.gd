class_name GameFlowPanel
extends CanvasLayer

var panel: PanelContainer
var time_label: Label
var phase_label: Label
var next_orders_label: Label
var cycle_label: Label
var action_button: Button

var game_clock: GameClock


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

	action_button.pressed.connect(_on_action_pressed)
	vbox.add_child(action_button)


func set_clock(clock: GameClock) -> void:
	game_clock = clock
	game_clock.phase_changed.connect(_on_phase_changed)
	cycle_label.text = "OODA cycle: %d min" % int(game_clock.ooda_cycle_minutes)


func _process(_delta: float) -> void:
	if game_clock == null:
		return

	time_label.text = game_clock.get_time_string()

	if game_clock.is_orders_phase():
		next_orders_label.text = ""
	else:
		var mins := game_clock.get_minutes_until_orders()
		next_orders_label.text = "Next orders in: %d min" % ceili(mins)


func _on_phase_changed(phase: String) -> void:
	_update_phase_display(phase)


func _update_phase_display(phase: String) -> void:
	phase_label.text = phase
	if phase == "ORDERS":
		phase_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.3))
		action_button.text = "EXECUTE ORDERS"
		action_button.disabled = false
	else:
		phase_label.add_theme_color_override("font_color", Color(0.85, 0.65, 0.2))
		action_button.text = "EXECUTING..."
		action_button.disabled = true


func _on_action_pressed() -> void:
	if game_clock and game_clock.is_orders_phase():
		game_clock.end_orders_phase()
