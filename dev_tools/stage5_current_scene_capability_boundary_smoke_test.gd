extends SceneTree

const SCENE_ROOT := "res://scene"
const LOAD_COORDINATOR_PATH := (
	"res://scene/loading/game_load_coordinator.gd"
)
const NIGHT_FLASH_POOL_PATH := (
	"res://scene/lighting/night_vfx_flash_pool.gd"
)

var _function_regex := RegEx.new()
var _member_regex := RegEx.new()
var _current_scene_source_regex := RegEx.new()
var _assignment_tail_regex := RegEx.new()
var _whitespace_regex := RegEx.new()
var _failures: Array[String] = []


func _initialize() -> void:
	_compile_regexes()
	call_deferred(&"_run")


func _compile_regexes() -> void:
	_function_regex.compile(
		"^\\s*(?:static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\("
	)
	_member_regex.compile(
		"^\\s*var\\s+([A-Za-z_][A-Za-z0-9_]*)\\b"
	)
	_current_scene_source_regex.compile(
		(
			"(?:get_tree\\s*\\(\\s*\\)|[A-Za-z_][A-Za-z0-9_]*)"
			+ "\\s*\\.\\s*current_scene\\b"
		)
	)
	_assignment_tail_regex.compile(
		(
			"(?:^|\\s)(?:var\\s+)?([A-Za-z_][A-Za-z0-9_]*)"
			+ "(?:\\s*:[^=]+)?\\s*(?::=|=)\\s*$"
		)
	)
	_whitespace_regex.compile("\\s+")


func _run() -> void:
	var script_paths: Array[String] = []
	_collect_gd_scripts(SCENE_ROOT, script_paths)
	script_paths.sort()
	var report: Dictionary = {}
	for script_path in script_paths:
		_scan_script(script_path, report)
	_print_report(report, script_paths.size())


func _collect_gd_scripts(
	directory_path: String,
	output: Array[String]
) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		_failures.append("无法扫描目录：%s。" % directory_path)
		return
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if not entry_name.begins_with("."):
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				_collect_gd_scripts(child_path, output)
			elif entry_name.ends_with(".gd"):
				output.append(child_path)
		entry_name = directory.get_next()
	directory.list_dir_end()


func _scan_script(script_path: String, report: Dictionary) -> void:
	var source := FileAccess.get_file_as_string(script_path)
	if source.is_empty() and FileAccess.get_open_error() != OK:
		_failures.append("无法读取脚本：%s。" % script_path)
		return
	var lines := source.split("\n")
	var methods := _parse_methods(lines)
	var member_names := _collect_member_names(lines, methods)
	var method_analyses: Array[Dictionary] = []
	var sourced_member_aliases: Dictionary = {}

	for method in methods:
		var analysis := _analyze_method(lines, method)
		method_analyses.append(analysis)
		for alias_variant in analysis["aliases"]:
			var alias := str(alias_variant)
			if not member_names.has(alias):
				continue
			var source_lines: Array = sourced_member_aliases.get(alias, [])
			for line_number in analysis["source_lines"]:
				if not source_lines.has(line_number):
					source_lines.append(line_number)
			sourced_member_aliases[alias] = source_lines

	for analysis in method_analyses:
		if not analysis["source_lines"].is_empty():
			if _is_narrowly_allowed(script_path, analysis):
				continue
			var reason := "SceneTree.current_scene 场景根依赖"
			if not analysis["capabilities"].is_empty():
				reason = "SceneTree.current_scene + has_method/call 能力猜测"
			if _is_whitelist_method(script_path, analysis["name"]):
				reason = "白名单方法偏离已审核的窄行文模式"
			_add_violation(report, script_path, analysis, reason)

	# A current scene cached in a script member can be guessed through from
	# another method. Report those consumers separately so migration work is
	# grouped by the actual method that owns each dynamic call.
	for alias_variant in sourced_member_aliases:
		var alias := str(alias_variant)
		for analysis in method_analyses:
			var capabilities := _extract_dynamic_capabilities(
				analysis["body"],
				[alias]
			)
			if capabilities.is_empty():
				continue
			var dependent_analysis := analysis.duplicate(true)
			dependent_analysis["aliases"] = [alias]
			dependent_analysis["capabilities"] = capabilities
			dependent_analysis["member_source_lines"] = (
				sourced_member_aliases[alias]
			)
			_add_violation(
				report,
				script_path,
				dependent_analysis,
				"缓存 SceneTree.current_scene + has_method/call 能力猜测"
			)


func _parse_methods(lines: PackedStringArray) -> Array[Dictionary]:
	var starts: Array[Dictionary] = []
	for line_index in range(lines.size()):
		var clean_line := _strip_comment(lines[line_index])
		var match := _function_regex.search(clean_line)
		if match != null:
			starts.append({
				"name": match.get_string(1),
				"start": line_index,
			})

	var methods: Array[Dictionary] = []
	var first_method_start := lines.size()
	if not starts.is_empty():
		first_method_start = int(starts[0]["start"])
	if first_method_start > 0:
		methods.append({
			"name": "<script>",
			"start": 0,
			"end": first_method_start - 1,
		})
	for start_index in range(starts.size()):
		var end_line := lines.size() - 1
		if start_index + 1 < starts.size():
			end_line = int(starts[start_index + 1]["start"]) - 1
		methods.append({
			"name": starts[start_index]["name"],
			"start": starts[start_index]["start"],
			"end": end_line,
		})
	if methods.is_empty():
		methods.append({
			"name": "<script>",
			"start": 0,
			"end": maxi(lines.size() - 1, 0),
		})
	return methods


func _collect_member_names(
	lines: PackedStringArray,
	methods: Array[Dictionary]
) -> Dictionary:
	var names: Dictionary = {}
	var first_function_line := lines.size()
	for method in methods:
		if method["name"] != "<script>":
			first_function_line = int(method["start"])
			break
	for line_index in range(first_function_line):
		var clean_line := _strip_comment(lines[line_index])
		var match := _member_regex.search(clean_line)
		if match != null:
			names[match.get_string(1)] = true
	return names


func _analyze_method(
	lines: PackedStringArray,
	method: Dictionary
) -> Dictionary:
	var source_lines: Array[int] = []
	var source_expressions: Array[String] = []
	var aliases: Array[String] = []
	var start_line := int(method["start"])
	var end_line := int(method["end"])
	var clean_lines: PackedStringArray = []
	for line_index in range(start_line, end_line + 1):
		var clean_line := _strip_comment(lines[line_index])
		clean_lines.append(clean_line)
		for source_match in _current_scene_source_regex.search_all(clean_line):
			source_lines.append(line_index + 1)
			source_expressions.append(
				_squash_whitespace(source_match.get_string())
			)
			var prefix := clean_line.substr(0, source_match.get_start())
			var assignment_match := _assignment_tail_regex.search(prefix)
			if assignment_match != null:
				var alias := assignment_match.get_string(1)
				if not aliases.has(alias):
					aliases.append(alias)
	var body := "\n".join(clean_lines)
	var capabilities: Array[String] = []
	if not source_lines.is_empty():
		capabilities = _extract_dynamic_capabilities(body, aliases)
		capabilities.append_array(_extract_direct_dynamic_capabilities(body))
		capabilities = _sorted_unique(capabilities)
	return {
		"name": str(method["name"]),
		"start": start_line + 1,
		"body": body,
		"source_lines": source_lines,
		"source_expressions": source_expressions,
		"aliases": aliases,
		"capabilities": capabilities,
		"member_source_lines": [],
	}


func _extract_dynamic_capabilities(
	method_body: String,
	aliases: Array
) -> Array[String]:
	var capabilities: Array[String] = []
	for alias_variant in aliases:
		var alias := str(alias_variant)
		if not method_body.contains(alias):
			continue
		var capability_regex := RegEx.new()
		capability_regex.compile(
			(
				"(?s)\\b%s\\s*\\.\\s*(has_method|call)\\s*\\(\\s*"
				+ "(?:&\\s*)?(?:[\"']([^\"']+)[\"']|"
				+ "([A-Za-z_][A-Za-z0-9_]*))"
			) % alias
		)
		for match in capability_regex.search_all(method_body):
			var target := match.get_string(2)
			if target.is_empty():
				target = "<dynamic:%s>" % match.get_string(3)
			capabilities.append("%s:%s" % [match.get_string(1), target])
	return _sorted_unique(capabilities)


func _extract_direct_dynamic_capabilities(
	method_body: String
) -> Array[String]:
	var direct_regex := RegEx.new()
	direct_regex.compile(
		(
			"(?s)(?:get_tree\\s*\\(\\s*\\)|[A-Za-z_][A-Za-z0-9_]*)"
			+ "\\s*\\.\\s*current_scene\\s*\\.\\s*(has_method|call)"
			+ "\\s*\\(\\s*(?:&\\s*)?(?:[\"']([^\"']+)[\"']|"
			+ "([A-Za-z_][A-Za-z0-9_]*))"
		)
	)
	var capabilities: Array[String] = []
	for match in direct_regex.search_all(method_body):
		var target := match.get_string(2)
		if target.is_empty():
			target = "<dynamic:%s>" % match.get_string(3)
		capabilities.append("%s:%s" % [match.get_string(1), target])
	return _sorted_unique(capabilities)


func _is_narrowly_allowed(
	script_path: String,
	analysis: Dictionary
) -> bool:
	var method_name := str(analysis["name"])
	var body := _squash_whitespace(str(analysis["body"]))
	var source_expressions: Array = analysis["source_expressions"]
	var capabilities: Array[String] = analysis["capabilities"]
	if script_path == LOAD_COORDINATOR_PATH and method_name == "_poll_scene_switch":
		return (
			source_expressions.size() == 1
			and source_expressions[0] == "get_tree().current_scene"
			and _contains_all(body, [
				"var current_scene := get_tree().current_scene",
				"current_scene.scene_file_path != expected_scene_path",
				"_poll_runtime_preparation_capability(",
				"(current_scene as RuntimePreparationProvider).activate_runtime()",
			])
			and capabilities.is_empty()
			and _same_strings(
				_extract_alias_method_names(str(analysis["body"]), "current_scene"),
				[]
			)
		)
	if script_path == LOAD_COORDINATOR_PATH and method_name == "_on_back_pressed":
		return (
			source_expressions.size() == 2
			and source_expressions[0] == "get_tree().current_scene"
			and source_expressions[1] == "get_tree().current_scene"
			and body.contains(
				(
					"elif get_tree().current_scene == null or "
					+ "get_tree().current_scene.scene_file_path "
					+ "!= MAIN_MENU_SCENE_PATH:"
				)
			)
			and capabilities.is_empty()
		)
	if script_path == NIGHT_FLASH_POOL_PATH and method_name == "find_for":
		return (
			source_expressions.size() == 1
			and source_expressions[0] == "tree.current_scene"
			and _contains_all(body, [
				"var tree := source.get_tree()",
				"var current_scene := tree.current_scene",
				"tree.get_nodes_in_group(POOL_GROUP)",
				"current_scene.is_ancestor_of(candidate_pool)",
			])
			and capabilities.is_empty()
			and _same_strings(
				_extract_alias_method_names(str(analysis["body"]), "current_scene"),
				["is_ancestor_of"]
			)
		)
	return false


func _is_whitelist_method(script_path: String, method_name: String) -> bool:
	return (
		(
			script_path == LOAD_COORDINATOR_PATH
			and method_name in ["_poll_scene_switch", "_on_back_pressed"]
		)
		or (
			script_path == NIGHT_FLASH_POOL_PATH
			and method_name == "find_for"
		)
	)


func _extract_alias_method_names(
	method_body: String,
	alias: String
) -> Array[String]:
	var method_regex := RegEx.new()
	method_regex.compile(
		"(?s)\\b%s\\s*\\.\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\(" % alias
	)
	var names: Array[String] = []
	for match in method_regex.search_all(method_body):
		names.append(match.get_string(1))
	return _sorted_unique(names)


func _add_violation(
	report: Dictionary,
	script_path: String,
	analysis: Dictionary,
	reason: String
) -> void:
	var file_report: Dictionary = report.get(script_path, {})
	var method_key := "%s@%d" % [analysis["name"], analysis["start"]]
	var record: Dictionary = file_report.get(method_key, {
		"name": analysis["name"],
		"start": analysis["start"],
		"source_lines": [],
		"member_source_lines": [],
		"aliases": [],
		"capabilities": [],
		"reasons": [],
	})
	_merge_unique(record["source_lines"], analysis["source_lines"])
	_merge_unique(
		record["member_source_lines"],
		analysis.get("member_source_lines", [])
	)
	_merge_unique(record["aliases"], analysis["aliases"])
	_merge_unique(record["capabilities"], analysis["capabilities"])
	if not record["reasons"].has(reason):
		record["reasons"].append(reason)
	file_report[method_key] = record
	report[script_path] = file_report


func _merge_unique(target: Array, source: Array) -> void:
	for value in source:
		if not target.has(value):
			target.append(value)


func _print_report(report: Dictionary, scanned_script_count: int) -> void:
	if not _failures.is_empty():
		for failure in _failures:
			push_error(failure)
		print(
			"STAGE5_CURRENT_SCENE_CAPABILITY_BOUNDARY_SMOKE_TEST_FAILED "
			+ "scanner_errors=%d" % _failures.size()
		)
		quit(1)
		return
	if report.is_empty():
		print(
			"STAGE5_CURRENT_SCENE_CAPABILITY_BOUNDARY_SMOKE_TEST_OK "
			+ "scanned_scripts=%d" % scanned_script_count
		)
		quit(0)
		return

	var paths: Array = report.keys()
	paths.sort()
	var method_count := 0
	for script_path in paths:
		method_count += (report[script_path] as Dictionary).size()
	push_error(
		(
			"第5阶段 current_scene 静态边界尚未收敛："
			+ "%d 个文件、%d 个方法仍依赖场景根或动态能力猜测。"
		) % [paths.size(), method_count]
	)
	print(
		"STAGE5_CURRENT_SCENE_CAPABILITY_BOUNDARY_SMOKE_TEST_FAILED "
		+ "scanned_scripts=%d files=%d methods=%d"
		% [scanned_script_count, paths.size(), method_count]
	)
	for script_path in paths:
		print(script_path)
		var file_report := report[script_path] as Dictionary
		var method_keys: Array = file_report.keys()
		method_keys.sort_custom(
			func(left: String, right: String) -> bool:
				return int(file_report[left]["start"]) < int(file_report[right]["start"])
		)
		for method_key in method_keys:
			var record := file_report[method_key] as Dictionary
			var details: Array[String] = []
			if not record["source_lines"].is_empty():
				details.append("current_scene 行=%s" % [record["source_lines"]])
			if not record["member_source_lines"].is_empty():
				details.append("缓存来源行=%s" % [record["member_source_lines"]])
			if not record["aliases"].is_empty():
				details.append("别名=%s" % [record["aliases"]])
			if not record["capabilities"].is_empty():
				details.append("能力=%s" % [record["capabilities"]])
			details.append("原因=%s" % [record["reasons"]])
			print(
				"  - %s (起始行 %d): %s"
				% [record["name"], record["start"], "; ".join(details)]
			)
	quit(1)


func _contains_all(text: String, required_fragments: Array) -> bool:
	for fragment_variant in required_fragments:
		if not text.contains(str(fragment_variant)):
			return false
	return true


func _same_strings(left: Array, right: Array) -> bool:
	return _sorted_unique(left) == _sorted_unique(right)


func _sorted_unique(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value_variant in values:
		var value := str(value_variant)
		if not result.has(value):
			result.append(value)
	result.sort()
	return result


func _squash_whitespace(text: String) -> String:
	return _whitespace_regex.sub(text, " ", true).strip_edges()


func _strip_comment(line: String) -> String:
	var first_hash := line.find("#")
	if first_hash < 0:
		return line
	var quote := ""
	var escaped := false
	for character_index in range(line.length()):
		var character := line.substr(character_index, 1)
		if not quote.is_empty():
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == quote:
				quote = ""
			continue
		if character == "\"" or character == "'":
			quote = character
		elif character == "#":
			return line.substr(0, character_index)
	return line
