extends SceneTree

const SOURCE_ROOTS := [
	"res://resources",
	"res://scene",
]
const TEXT_RESOURCE_EXTENSIONS := ["tres", "tscn"]

var failures: Array[String] = []
var _uid_pattern := RegEx.new()
var _path_pattern := RegEx.new()
var _text_resource_count := 0
var _uid_reference_count := 0


func _init() -> void:
	_uid_pattern.compile('uid="(uid://[^"]+)"')
	_path_pattern.compile('path="(res://[^"]+)"')
	for root_path in SOURCE_ROOTS:
		_scan_directory(root_path)
	_expect(_text_resource_count >= 1000, "UID audit must scan the production text resources.")
	_expect(_uid_reference_count >= 1000, "UID audit must inspect production ext_resource links.")

	if failures.is_empty():
		print("RESOURCE_UID_REFERENCE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _scan_directory(directory_path: String) -> void:
	for file_name in DirAccess.get_files_at(directory_path):
		if file_name.get_extension() in TEXT_RESOURCE_EXTENSIONS:
			_scan_text_resource("%s/%s" % [directory_path, file_name])
	for child_name in DirAccess.get_directories_at(directory_path):
		_scan_directory("%s/%s" % [directory_path, child_name])


func _scan_text_resource(source_path: String) -> void:
	_text_resource_count += 1
	var file := FileAccess.open(source_path, FileAccess.READ)
	_expect(file != null, "Text resource must be readable: %s" % source_path)
	if file == null:
		return
	var line_number := 0
	while not file.eof_reached():
		line_number += 1
		var line := file.get_line()
		if not line.begins_with("[ext_resource "):
			continue
		var uid_match := _uid_pattern.search(line)
		var path_match := _path_pattern.search(line)
		if uid_match == null or path_match == null:
			continue
		_uid_reference_count += 1
		var declared_uid_text := uid_match.get_string(1)
		var target_path := path_match.get_string(1)
		var declared_uid := ResourceUID.text_to_id(declared_uid_text)
		var authoritative_uid_text := _get_authoritative_uid_text(target_path)
		var actual_uid := ResourceUID.text_to_id(authoritative_uid_text)
		_expect(
			actual_uid != ResourceUID.INVALID_ID,
			"%s:%d references a target without a registered UID: %s"
			% [source_path, line_number, target_path]
		)
		if actual_uid == ResourceUID.INVALID_ID:
			continue
		_expect(
			declared_uid == actual_uid,
			(
				"%s:%d declares stale UID %s for %s; authoritative UID is %s."
			)
			% [
				source_path,
				line_number,
				declared_uid_text,
				target_path,
				authoritative_uid_text,
			]
		)


func _get_authoritative_uid_text(target_path: String) -> String:
	var extension := target_path.get_extension()
	if extension in TEXT_RESOURCE_EXTENSIONS:
		var target_file := FileAccess.open(target_path, FileAccess.READ)
		if target_file != null:
			var header_match := _uid_pattern.search(target_file.get_line())
			if header_match != null:
				return header_match.get_string(1)
	elif extension == "gd":
		var sidecar_path := "%s.uid" % target_path
		if FileAccess.file_exists(sidecar_path):
			var sidecar := FileAccess.get_file_as_string(sidecar_path).strip_edges()
			if sidecar.begins_with("uid://"):
				return sidecar
	var imported_uid := ResourceLoader.get_resource_uid(target_path)
	return (
		ResourceUID.id_to_text(imported_uid)
		if imported_uid != ResourceUID.INVALID_ID
		else ""
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
