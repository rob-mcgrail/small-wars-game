class_name GameFlowPanel
extends CanvasLayer

signal toggle_pause()

var panel: PanelContainer
var time_label: Label
var daynight_label: Label
var phase_label: Label
var action_button: Button

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

	# Status + speed indicator
	phase_label = Label.new()
	phase_label.add_theme_font_size_override("font_size", 14)
	phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phase_label.text = "PAUSED"
	phase_label.add_theme_color_override("font_color", Color(0.85, 0.7, 1.0))
	vbox.add_child(phase_label)

	var speed_label := Label.new()
	speed_label.name = "SpeedLabel"
	speed_label.add_theme_font_size_override("font_size", 12)
	speed_label.add_theme_color_override("font_color", Color(0.55, 0.58, 0.5))
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_label.text = "Speed: 2x (1/2/3/4)"
	vbox.add_child(speed_label)

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Color(0.3, 0.32, 0.25, 0.3))
	vbox.add_child(sep)

	# Action button
	action_button = Button.new()
	action_button.text = "PAUSED [Space]"
	action_button.custom_minimum_size = Vector2(0, 36)
	action_button.add_theme_font_size_override("font_size", 14)
	action_button.focus_mode = Control.FOCUS_NONE  # prevent Space key double-toggle

	action_button.pressed.connect(_on_action_pressed)
	vbox.add_child(action_button)

	# Start with paused style
	_set_button_style_purple()


func set_clock(clock: GameClock) -> void:
	game_clock = clock


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


func set_paused(is_paused: bool) -> void:
	if is_paused:
		phase_label.text = "PAUSED"
		phase_label.add_theme_color_override("font_color", Color(0.85, 0.7, 1.0))
		action_button.text = "PAUSED [Space]"
		action_button.disabled = false
		_set_button_style_purple()
	else:
		phase_label.text = "RUNNING"
		phase_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.3))
		action_button.text = "RUNNING [Space]"
		action_button.disabled = false
		_set_button_style_green()


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
	var h := s.duplicate()
	h.bg_color = Color(0.3, 0.42, 0.25, 0.9)
	action_button.add_theme_stylebox_override("hover", h)


func _set_button_style_purple() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.35, 0.15, 0.5, 0.9)
	s.border_color = Color(0.6, 0.3, 0.8)
	s.border_width_top = 1; s.border_width_left = 1
	s.border_width_right = 1; s.border_width_bottom = 1
	s.corner_radius_top_left = 2; s.corner_radius_top_right = 2
	s.corner_radius_bottom_left = 2; s.corner_radius_bottom_right = 2
	s.content_margin_left = 8.0; s.content_margin_right = 8.0
	s.content_margin_top = 4.0; s.content_margin_bottom = 4.0
	action_button.add_theme_stylebox_override("normal", s)
	action_button.add_theme_color_override("font_color", Color(0.85, 0.7, 1.0))
	var h := s.duplicate()
	h.bg_color = Color(0.45, 0.2, 0.6, 0.9)
	action_button.add_theme_stylebox_override("hover", h)


func set_speed(speed: int) -> void:
	var speed_names := ["", "1x Slow", "2x Normal", "3x Fast", "4x Very Fast"]
	var label_node := panel.find_child("SpeedLabel", true, false)
	if label_node and label_node is Label:
		label_node.text = "Speed: %s (1/2/3/4)" % speed_names[clampi(speed, 1, 4)]


func _on_action_pressed() -> void:
	toggle_pause.emit()
