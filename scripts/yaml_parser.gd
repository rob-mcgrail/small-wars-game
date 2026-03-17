class_name YamlParser
extends RefCounted

## Simple YAML parser supporting scalars, lists, and nested dictionaries.
## Handles basic YAML sufficient for game configuration files.


static func parse_file(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("YamlParser: Cannot open file: %s" % path)
		return null
	var text := file.get_as_text()
	file.close()
	return parse(text)


static func parse(text: String) -> Variant:
	var lines := text.split("\n")
	var cleaned: Array[String] = []
	for line in lines:
		# Skip empty lines and comments
		var stripped := line.replace("\t", "    ")
		if stripped.strip_edges() == "" or stripped.strip_edges().begins_with("#"):
			continue
		cleaned.append(stripped)
	var ctx := {"lines": cleaned, "pos": 0}
	return _parse_value(ctx, 0)


static func _current_indent(line: String) -> int:
	var count := 0
	for c in line:
		if c == " ":
			count += 1
		else:
			break
	return count


static func _parse_value(ctx: Dictionary, min_indent: int) -> Variant:
	if ctx["pos"] >= ctx["lines"].size():
		return null

	var line: String = ctx["lines"][ctx["pos"]]
	var indent := _current_indent(line)

	if indent < min_indent:
		return null

	var stripped := line.strip_edges()

	# Check if this is a list item
	if stripped.begins_with("- "):
		return _parse_list(ctx, indent)

	# Check if this is a mapping
	if ":" in stripped:
		return _parse_dict(ctx, indent)

	# Scalar
	ctx["pos"] += 1
	return _parse_scalar(stripped)


static func _parse_dict(ctx: Dictionary, base_indent: int) -> Dictionary:
	var result := {}
	while ctx["pos"] < ctx["lines"].size():
		var line: String = ctx["lines"][ctx["pos"]]
		var indent := _current_indent(line)

		if indent < base_indent:
			break
		if indent > base_indent:
			break

		var stripped := line.strip_edges()
		var colon_pos := stripped.find(":")
		if colon_pos == -1:
			break

		var key := stripped.substr(0, colon_pos).strip_edges()
		var after_colon := stripped.substr(colon_pos + 1).strip_edges()

		if after_colon == "|" or after_colon == ">":
			# Literal block scalar (|) or folded scalar (>)
			ctx["pos"] += 1
			var block_lines: Array[String] = []
			while ctx["pos"] < ctx["lines"].size():
				var block_line: String = ctx["lines"][ctx["pos"]]
				var block_indent := _current_indent(block_line)
				if block_indent <= base_indent:
					break  # Back to same or lower indent = end of block
				block_lines.append(block_line.strip_edges())
				ctx["pos"] += 1
			if after_colon == "|":
				result[key] = "\n".join(block_lines)
			else:
				result[key] = " ".join(block_lines)
		elif after_colon != "":
			# Inline value
			result[key] = _parse_scalar(after_colon)
			ctx["pos"] += 1
		else:
			# Value on next line(s)
			ctx["pos"] += 1
			if ctx["pos"] < ctx["lines"].size():
				var next_indent := _current_indent(ctx["lines"][ctx["pos"]])
				if next_indent > base_indent:
					result[key] = _parse_value(ctx, next_indent)
				else:
					result[key] = null
			else:
				result[key] = null

	return result


static func _parse_list(ctx: Dictionary, base_indent: int) -> Array:
	var result := []
	while ctx["pos"] < ctx["lines"].size():
		var line: String = ctx["lines"][ctx["pos"]]
		var indent := _current_indent(line)

		if indent < base_indent:
			break
		if indent > base_indent:
			break

		var stripped := line.strip_edges()
		if not stripped.begins_with("- "):
			break

		var item_text := stripped.substr(2).strip_edges()

		# Check if the list item has a key (list of dicts)
		if ":" in item_text:
			# Rewrite as dict entry at deeper indent and parse
			var sub_lines: Array[String] = []
			var sub_indent := indent + 2
			var spaces := ""
			for i in range(sub_indent):
				spaces += " "
			sub_lines.append(spaces + item_text)
			ctx["pos"] += 1

			# Grab any continuation lines
			while ctx["pos"] < ctx["lines"].size():
				var next_line: String = ctx["lines"][ctx["pos"]]
				var next_indent := _current_indent(next_line)
				if next_indent > indent + 2:
					sub_lines.append(next_line)
					ctx["pos"] += 1
				elif next_indent > indent:
					sub_lines.append(next_line)
					ctx["pos"] += 1
				else:
					break

			var sub_ctx := {"lines": sub_lines, "pos": 0}
			result.append(_parse_value(sub_ctx, sub_indent))
		else:
			result.append(_parse_scalar(item_text))
			ctx["pos"] += 1

	return result


static func _parse_scalar(text: String) -> Variant:
	if text == "true" or text == "True":
		return true
	if text == "false" or text == "False":
		return false
	if text == "null" or text == "~":
		return null
	if text == "[]":
		return []
	if text == "{}":
		return {}

	# Remove quotes
	if (text.begins_with("\"") and text.ends_with("\"")) or \
	   (text.begins_with("'") and text.ends_with("'")):
		return text.substr(1, text.length() - 2)

	# Try integer
	if text.is_valid_int():
		return text.to_int()

	# Try float
	if text.is_valid_float():
		return text.to_float()

	return text
