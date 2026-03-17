extends Control

signal map_selected(path: String)
signal scenario_selected(path: String)

@onready var map_list: VBoxContainer = %MapList
@onready var description_label: Label = %DescriptionLabel


func _ready() -> void:
	_scan_scenarios()
	_scan_maps()


func _scan_maps() -> void:
	# Section header
	var header := Label.new()
	header.text = "Maps (Sandbox)"
	header.add_theme_font_size_override("font_size", 26)
	header.add_theme_color_override("font_color", Color(0.65, 0.62, 0.55, 1.0))
	map_list.add_child(header)

	var dir := DirAccess.open("res://maps")
	if dir == null:
		push_error("MapMenu: Cannot open maps directory")
		return

	dir.list_dir_begin()
	var files: Array[String] = []
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".yaml"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	files.sort()

	for file in files:
		var path := "res://maps/" + file
		var cfg := Config.new()
		if not cfg.load_file(path):
			continue

		var btn := Button.new()
		btn.text = cfg.get_string("name", file)
		btn.custom_minimum_size = Vector2(400, 50)
		btn.add_theme_font_size_override("font_size", 20)

		var desc := cfg.get_string("description", "")
		var cols := cfg.get_int("cols", 0)
		var rows := cfg.get_int("rows", 0)
		var info := "%s (%dx%d)" % [desc, cols, rows]

		btn.pressed.connect(_on_map_button_pressed.bind(path, info))
		btn.mouse_entered.connect(_on_map_button_hover.bind(info))
		map_list.add_child(btn)


func _scan_scenarios() -> void:
	# Scan for folder-based scenarios in res://scenarios/
	var dir := DirAccess.open("res://scenarios")
	if dir == null:
		# No scenarios directory yet, that's fine
		return

	dir.list_dir_begin()
	var folders: Array[String] = []
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir() and not fname.begins_with("."):
			# Check if this folder contains a scenario.yaml
			if FileAccess.file_exists("res://scenarios/" + fname + "/scenario.yaml"):
				folders.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	if folders.is_empty():
		return

	folders.sort()

	# Section header
	var header := Label.new()
	header.text = "Scenarios"
	header.add_theme_font_size_override("font_size", 26)
	header.add_theme_color_override("font_color", Color(0.85, 0.75, 0.5, 1.0))
	map_list.add_child(header)

	for folder in folders:
		var path := "res://scenarios/" + folder + "/"
		var loader := ScenarioLoader.new()
		if not loader.load_scenario(path):
			continue

		var btn := Button.new()
		btn.text = loader.name
		btn.custom_minimum_size = Vector2(400, 50)
		btn.add_theme_font_size_override("font_size", 20)

		var info := loader.description

		btn.pressed.connect(_on_scenario_button_pressed.bind(path, info))
		btn.mouse_entered.connect(_on_map_button_hover.bind(info))
		map_list.add_child(btn)


func _on_map_button_pressed(path: String, _info: String) -> void:
	map_selected.emit(path)


func _on_scenario_button_pressed(path: String, _info: String) -> void:
	scenario_selected.emit(path)


func _on_map_button_hover(info: String) -> void:
	description_label.text = info
