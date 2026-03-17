extends Control

signal map_selected(path: String)
signal scenario_selected(path: String)

@onready var map_list: VBoxContainer = %MapList
@onready var description_label: Label = %DescriptionLabel


func _ready() -> void:
	_scan_conflicts()
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


func _scan_conflicts() -> void:
	## Scan res://conflicts/ for conflict folders. Within each, scan scenarios/.
	## Display as conflict name headers with scenario buttons underneath.
	var conflicts_dir := DirAccess.open("res://conflicts")
	if conflicts_dir == null:
		# No conflicts directory yet, that's fine
		return

	conflicts_dir.list_dir_begin()
	var conflict_folders: Array[String] = []
	var fname := conflicts_dir.get_next()
	while fname != "":
		if conflicts_dir.current_is_dir() and not fname.begins_with("."):
			conflict_folders.append(fname)
		fname = conflicts_dir.get_next()
	conflicts_dir.list_dir_end()

	if conflict_folders.is_empty():
		return

	conflict_folders.sort()

	for conflict_folder in conflict_folders:
		var conflict_path: String = "res://conflicts/" + conflict_folder + "/"
		var scenarios: Array[Dictionary] = _find_scenarios_in_conflict(conflict_path)

		if scenarios.is_empty():
			continue

		# Conflict header - derive display name from folder name
		var conflict_display_name: String = _folder_to_display_name(conflict_folder)
		var header := Label.new()
		header.text = conflict_display_name
		header.add_theme_font_size_override("font_size", 26)
		header.add_theme_color_override("font_color", Color(0.85, 0.75, 0.5, 1.0))
		map_list.add_child(header)

		# Scenario buttons under this conflict
		for scenario_info in scenarios:
			var btn := Button.new()
			btn.text = "  " + scenario_info["name"]
			btn.custom_minimum_size = Vector2(400, 50)
			btn.add_theme_font_size_override("font_size", 20)

			var info: String = scenario_info["description"]
			var path: String = scenario_info["path"]

			btn.pressed.connect(_on_scenario_button_pressed.bind(path, info))
			btn.mouse_entered.connect(_on_map_button_hover.bind(info))
			map_list.add_child(btn)


func _find_scenarios_in_conflict(conflict_path: String) -> Array[Dictionary]:
	## Find all scenario folders within a conflict's scenarios/ directory.
	var result: Array[Dictionary] = []
	var scenarios_path: String = conflict_path + "scenarios/"
	var dir := DirAccess.open(scenarios_path)
	if dir == null:
		return result

	dir.list_dir_begin()
	var folders: Array[String] = []
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir() and not fname.begins_with("."):
			if FileAccess.file_exists(scenarios_path + fname + "/scenario.yaml"):
				folders.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	folders.sort()

	for folder in folders:
		var path: String = scenarios_path + folder + "/"
		var loader := ScenarioLoader.new()
		if not loader.load_scenario(path):
			continue
		result.append({
			"name": loader.name,
			"description": loader.description,
			"path": path,
		})

	return result


func _folder_to_display_name(folder_name: String) -> String:
	## Convert a folder name like "southern_lebanon_2006" to "Southern Lebanon 2006".
	var parts: PackedStringArray = folder_name.split("_")
	var display_parts: Array[String] = []
	for part in parts:
		if part.length() > 0:
			# Check if this part is a number (year, etc.) - don't capitalize
			if part.is_valid_int():
				display_parts.append(part)
			else:
				display_parts.append(part.capitalize())
	return " ".join(display_parts)


func _on_map_button_pressed(path: String, _info: String) -> void:
	map_selected.emit(path)


func _on_scenario_button_pressed(path: String, _info: String) -> void:
	scenario_selected.emit(path)


func _on_map_button_hover(info: String) -> void:
	description_label.text = info
