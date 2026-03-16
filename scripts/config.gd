class_name Config
extends RefCounted

## Loads and provides access to YAML game configuration.
## Usage: var cfg = Config.new(); cfg.load_file("res://config/map.yaml")

var data := {}


func load_file(path: String) -> bool:
	var result = YamlParser.parse_file(path)
	if result == null:
		push_error("Config: Failed to load %s" % path)
		return false
	if result is Dictionary:
		data = result
		return true
	push_error("Config: Root of %s must be a dictionary" % path)
	return false


func get_value(key_path: String, default: Variant = null) -> Variant:
	## Access nested values with dot notation: "map.hex_size"
	var keys := key_path.split(".")
	var current: Variant = data
	for key in keys:
		if current is Dictionary and key in current:
			current = current[key]
		else:
			return default
	return current


func get_int(key_path: String, default: int = 0) -> int:
	var val = get_value(key_path, default)
	return int(val)


func get_float(key_path: String, default: float = 0.0) -> float:
	var val = get_value(key_path, default)
	return float(val)


func get_string(key_path: String, default: String = "") -> String:
	var val = get_value(key_path, default)
	return str(val)


func get_bool(key_path: String, default: bool = false) -> bool:
	var val = get_value(key_path, default)
	return bool(val)


func get_color(key_path: String, default: Color = Color.WHITE) -> Color:
	var val = get_value(key_path)
	if val is String:
		return Color(val)
	return default
