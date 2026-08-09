extends SceneTree

## Stage 5 refactors runtime ownership, but it must not silently change any
## network-facing method or scene identity. The three hashes below deliberately
## cover separate dimensions so a failure identifies whether names, arguments,
## or @rpc transport metadata drifted.

const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const MP_ROGUE_ROUTE_SOURCE_PATH := "res://scene/multiplayer/mp_rogue_route.gd"
const ROGUE_COMBAT_COORDINATOR_SOURCE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd"
)

const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")

const EXPECTED_MP_GAME_RPC_COUNT := 126
const EXPECTED_MP_GAME_RPC_NAME_HASH := (
	"a46021f28a7b751d4d14ab568deac088bf47b615c265a4ef1cc4d8d75fabfa27"
)
const EXPECTED_MP_GAME_RPC_SIGNATURE_HASH := (
	"fa6c2ea251939a8eb218217e152262e19626ec506a7ab03285927ad046ed5354"
)
const EXPECTED_MP_GAME_RPC_ANNOTATION_HASH := (
	"96e6b2976861a125f91888717319b7e26d1596b1a0c42a0c641e9932648163b8"
)

const EXPECTED_MP_ROGUE_ROUTE_RPC_COUNT := 16
const EXPECTED_MP_ROGUE_ROUTE_RPC_NAME_HASH := (
	"4cb5d6bf01d8cf32847856fa9b11bcf7cf2f9fd99643b75b4e4918c85c850136"
)
const EXPECTED_MP_ROGUE_ROUTE_RPC_SIGNATURE_HASH := (
	"19512528aae0dc803c4836a0569dab8928b9e9fb801c77a934138be3484da815"
)
const EXPECTED_MP_ROGUE_ROUTE_RPC_ANNOTATION_HASH := (
	"a572289259bd54ed1ffe876c17e70bb05738e5b6bd546f923b8004c16e0208a9"
)

const EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_COUNT := 10
const EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_NAME_HASH := (
	"5c54e2b0ce2ee265b9d3417d504de69c8f609e6c5fca871b043da0da42377d59"
)
const EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_SIGNATURE_HASH := (
	"ce4bfa4998d4f03a3c02a7b103d16ca71976230e6475184391ab54bd2eb8446e"
)
const EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_ANNOTATION_HASH := (
	"272a50890bb520168b9b1de6829cde1f00cb89bfb0fc52c704781aced99cec4e"
)

const EXPECTED_MODE_WIRE_KEYS := {
	0: &"standard",
	1: &"tower_defense",
	2: &"test_arena_p1",
	3: &"test_arena_p2",
	4: &"test_arena_p3",
	5: &"test_arena_p1b",
}

const STANDARD_GAME_SCENE_PATH := (
	"res://scene/game_modes/standard/standard_game.tscn"
)
const TOWER_DEFENSE_GAME_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ROGUE_ROUTE_SCENE_PATH := (
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)
const ROGUE_COMBAT_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const MP_GAME_SCENE_PATH := "res://scene/multiplayer/mp_game.tscn"
const MP_ROGUE_ROUTE_SCENE_PATH := "res://scene/multiplayer/mp_rogue_route.tscn"

const ROGUE_COMBAT_NETWORK_PATH := NodePath(
	"RogueCombatCoordinator/RogueCombatNetwork"
)

var failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_rpc_surface(
		"MpGame",
		MP_GAME_SOURCE_PATH,
		EXPECTED_MP_GAME_RPC_COUNT,
		EXPECTED_MP_GAME_RPC_NAME_HASH,
		EXPECTED_MP_GAME_RPC_SIGNATURE_HASH,
		EXPECTED_MP_GAME_RPC_ANNOTATION_HASH
	)
	_test_rpc_surface(
		"MpRogueRoute",
		MP_ROGUE_ROUTE_SOURCE_PATH,
		EXPECTED_MP_ROGUE_ROUTE_RPC_COUNT,
		EXPECTED_MP_ROGUE_ROUTE_RPC_NAME_HASH,
		EXPECTED_MP_ROGUE_ROUTE_RPC_SIGNATURE_HASH,
		EXPECTED_MP_ROGUE_ROUTE_RPC_ANNOTATION_HASH
	)
	_test_rpc_surface(
		"RogueCombatCoordinator",
		ROGUE_COMBAT_COORDINATOR_SOURCE_PATH,
		EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_COUNT,
		EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_NAME_HASH,
		EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_SIGNATURE_HASH,
		EXPECTED_ROGUE_COMBAT_COORDINATOR_RPC_ANNOTATION_HASH
	)
	_test_protocol_and_wire_values()
	_test_scene_uid_contracts()
	_test_scene_node_paths()
	_test_rogue_combat_network_path()
	_finish()


func _test_rpc_surface(
	label: String,
	source_path: String,
	expected_count: int,
	expected_name_hash: String,
	expected_signature_hash: String,
	expected_annotation_hash: String
) -> void:
	var surface := _extract_rpc_surface(source_path)
	var names := surface.get("names", PackedStringArray()) as PackedStringArray
	var signatures := (
		surface.get("signatures", PackedStringArray()) as PackedStringArray
	)
	var annotations := (
		surface.get("annotations", PackedStringArray()) as PackedStringArray
	)
	var annotation_by_name := (
		surface.get("annotation_by_name", {}) as Dictionary
	)
	_expect(
		names.size() == expected_count,
		"%s RPC 数量必须保持 %d，实际为 %d。"
		% [label, expected_count, names.size()]
	)
	_expect_surface_hash(
		label,
		"方法名",
		names,
		expected_name_hash
	)
	_expect_surface_hash(
		label,
		"参数签名",
		signatures,
		expected_signature_hash
	)
	_expect_surface_hash(
		label,
		"@rpc 配置/信道",
		annotations,
		expected_annotation_hash
	)
	_validate_effective_rpc_config(
		label,
		source_path,
		names,
		annotation_by_name,
		expected_count
	)


func _extract_rpc_surface(source_path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(source_path)
	_expect(not source.is_empty(), "无法读取 RPC 源码：%s。" % source_path)
	if source.is_empty():
		return {}

	var block_regex := RegEx.new()
	var block_error := block_regex.compile(
		(
			"(?ms)^@rpc\\(([^\\r\\n]+)\\)\\r?\\n"
			+ "func\\s+([A-Za-z0-9_]+)\\s*\\((.*?)\\)\\s*->\\s*void:"
		)
	)
	_expect(block_error == OK, "无法编译 RPC 冻结解析表达式。")
	if block_error != OK:
		return {}
	var whitespace_regex := RegEx.new()
	var whitespace_error := whitespace_regex.compile("\\s+")
	_expect(whitespace_error == OK, "无法编译 RPC 空白归一化表达式。")
	if whitespace_error != OK:
		return {}

	var signature_by_name: Dictionary[String, String] = {}
	var annotation_by_name: Dictionary[String, String] = {}
	for block_match in block_regex.search_all(source):
		var method_name := block_match.get_string(2)
		_expect(
			not signature_by_name.has(method_name),
			"%s 中出现重复 RPC：%s。" % [source_path, method_name]
		)
		var arguments := whitespace_regex.sub(
			block_match.get_string(3),
			"",
			true
		)
		var annotation := whitespace_regex.sub(
			block_match.get_string(1),
			"",
			true
		)
		signature_by_name[method_name] = "%s(%s)->void" % [
			method_name,
			arguments,
		]
		annotation_by_name[method_name] = annotation

	var names := PackedStringArray(signature_by_name.keys())
	names.sort()
	var signatures := PackedStringArray()
	var annotations := PackedStringArray()
	for method_name in names:
		signatures.append(signature_by_name[method_name])
		annotations.append(
			"%s|%s" % [method_name, annotation_by_name[method_name]]
		)
	return {
		"names": names,
		"signatures": signatures,
		"annotations": annotations,
		"annotation_by_name": annotation_by_name,
	}


func _expect_surface_hash(
	label: String,
	dimension: String,
	lines: PackedStringArray,
	expected_hash: String
) -> void:
	var canonical := "\n".join(lines)
	var actual_hash := canonical.sha256_text()
	if actual_hash == expected_hash:
		return
	failures.append(
		"%s RPC %s已偏离冻结基线：expected=%s actual=%s。\n实际表面：\n%s"
		% [label, dimension, expected_hash, actual_hash, canonical]
	)


func _validate_effective_rpc_config(
	label: String,
	source_path: String,
	names: PackedStringArray,
	annotation_by_name: Dictionary,
	expected_count: int
) -> void:
	var script := load(source_path) as Script
	_expect(script != null, "%s 脚本无法加载，不能校验有效 RPC 配置。" % label)
	if script == null:
		return
	var rpc_config: Dictionary = script.get_rpc_config()
	_expect(
		rpc_config.size() == expected_count,
		"%s Script.get_rpc_config() 必须包含 %d 项，实际为 %d。"
		% [label, expected_count, rpc_config.size()]
	)
	for method_name in names:
		var config := rpc_config.get(StringName(method_name), {}) as Dictionary
		_expect(not config.is_empty(), "%s 缺少有效 RPC 配置：%s。" % [label, method_name])
		if config.is_empty():
			continue
		var annotation := String(annotation_by_name.get(method_name, ""))
		var expected := _parse_rpc_annotation(annotation)
		if expected.is_empty():
			continue
		_expect(
			int(config.get("rpc_mode", -1)) == int(expected["rpc_mode"])
			and bool(config.get("call_local", true)) == bool(expected["call_local"])
			and int(config.get("transfer_mode", -1))
			== int(expected["transfer_mode"])
			and int(config.get("channel", -1)) == int(expected["channel"]),
			(
				"%s RPC %s 的运行时配置与冻结 @rpc 声明不一致：%s。"
				% [label, method_name, config]
			)
		)


func _parse_rpc_annotation(annotation: String) -> Dictionary:
	var parts := annotation.split(",", false)
	_expect(parts.size() == 4, "RPC 声明必须显式给出权限/本地调用/可靠性/信道：%s。" % annotation)
	if parts.size() != 4:
		return {}
	var authority := _strip_quotes(parts[0])
	var local_call := _strip_quotes(parts[1])
	var transfer := _strip_quotes(parts[2])
	var transfer_mode := -1
	match transfer:
		"unreliable":
			transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		"unreliable_ordered":
			transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		"reliable":
			transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
		_:
			failures.append("未知 RPC transfer mode：%s。" % transfer)
	return {
		"rpc_mode": (
			MultiplayerAPI.RPC_MODE_ANY_PEER
			if authority == "any_peer"
			else MultiplayerAPI.RPC_MODE_AUTHORITY
		),
		"call_local": local_call == "call_local",
		"transfer_mode": transfer_mode,
		"channel": int(parts[3]),
	}


func _strip_quotes(value: String) -> String:
	return value.trim_prefix('"').trim_suffix('"')


func _test_protocol_and_wire_values() -> void:
	_expect(NET_CONSTANTS.PROTOCOL_VERSION == 48, "多人协议必须保持 v48。")
	_expect(NET_CONSTANTS.CHANNEL_COUNT == 8, "v48 必须保持 8 个 ENet 信道。")
	_expect(GameModeCatalog.MODE_STANDARD == 0, "standard wire value 必须保持 0。")
	_expect(GameModeCatalog.MODE_TOWER_DEFENSE == 1, "tower_defense wire value 必须保持 1。")
	_expect(GameModeCatalog.MODE_TEST_ARENA_P1 == 2, "test_arena_p1 wire value 必须保持 2。")
	_expect(GameModeCatalog.MODE_TEST_ARENA_P2 == 3, "test_arena_p2 wire value 必须保持 3。")
	_expect(GameModeCatalog.MODE_TEST_ARENA_P3 == 4, "test_arena_p3 wire value 必须保持 4。")
	_expect(GameModeCatalog.MODE_TEST_ARENA_P1B == 5, "test_arena_p1b wire value 必须保持 5。")
	_expect(NetManagerStore.GameMode.STANDARD == 0, "NetManager standard wire value 改变。")
	_expect(NetManagerStore.GameMode.TOWER_DEFENSE == 1, "NetManager tower wire value 改变。")
	_expect(NetManagerStore.GameMode.TEST_ARENA_P3 == 4, "NetManager Rogue wire value 改变。")
	for mode_id_variant in EXPECTED_MODE_WIRE_KEYS:
		var mode_id := int(mode_id_variant)
		var expected_key := EXPECTED_MODE_WIRE_KEYS[mode_id] as StringName
		var definition := GameModeCatalog.get_definition(mode_id)
		_expect(definition != null, "缺少模式定义：%d。" % mode_id)
		if definition == null:
			continue
		_expect(
			definition.mode_id == mode_id
			and definition.wire_key == expected_key
			and GameModeCatalog.resolve_wire_key_or_default(String(expected_key))
			== mode_id,
			"模式 %d 的 wire key/value 往返契约改变。" % mode_id
		)

	var expected_flow_values := {
		"PRE_WAVE": 0,
		"WAVE_ACTIVE": 1,
		"INTERMISSION": 2,
		"VICTORY": 3,
		"DEFEAT": 4,
		"BOSS_INTRO": 5,
		"BOSS_ACTIVE": 6,
		"FATE_INTERLUDE": 7,
	}
	for state_name in expected_flow_values:
		_expect(
			int(CombatFlowState.State.get(state_name, -1))
			== int(expected_flow_values[state_name]),
			"CombatFlowState.%s 的 v48 wire value 改变。" % state_name
		)


func _test_scene_uid_contracts() -> void:
	_expect_scene_uid(
		STANDARD_GAME_SCENE_PATH,
		"uid://dcqarxlpbdh8y"
	)
	_expect_scene_uid(
		TOWER_DEFENSE_GAME_SCENE_PATH,
		"uid://dy51i4e27gaoi"
	)
	_expect_scene_uid(
		ROGUE_COMBAT_SCENE_PATH,
		"uid://cxpm27hl7fmro"
	)
	# The route .tscn currently has no authored scene UID. Freeze the mode root
	# script plus its combat-runtime scene UID instead of relying on editor cache.
	_expect_uid_file(
		"res://scene/game_modes/standard/standard_game.gd.uid",
		"uid://7lyj58pu4nvs"
	)
	_expect_uid_file(
		"res://scene/game_modes/tower_defense/tower_defense_game.gd.uid",
		"uid://d1w121mq74kpw"
	)
	_expect_uid_file(
		"res://scene/game_modes/rogue/route/rogue_route_game.gd.uid",
		"uid://djtb4iw8wk0m6"
	)
	_expect_uid_file(
		"res://scene/game_modes/rogue/combat/rogue_combat_game.gd.uid",
		"uid://ctfnnphhg0fm"
	)


func _expect_scene_uid(path: String, expected_uid: String) -> void:
	var source := FileAccess.get_file_as_string(path)
	_expect(not source.is_empty(), "无法读取根场景：%s。" % path)
	_expect(
		source.begins_with("[gd_scene format=4 uid=\"%s\"]" % expected_uid),
		"根场景 UID 改变：%s。" % path
	)


func _expect_uid_file(path: String, expected_uid: String) -> void:
	_expect(
		FileAccess.get_file_as_string(path).strip_edges() == expected_uid,
		"脚本 UID 改变：%s。" % path
	)


func _test_scene_node_paths() -> void:
	_test_packed_scene_structure(
		"StandardGame",
		STANDARD_GAME_SCENE_PATH,
		&"StandardGame",
		[
			NodePath("MultiplayerGameplayGateway"),
			NodePath("MultiplayerModeAdapter"),
			NodePath("DayNightController"),
			NodePath("EnemyContainer"),
			NodePath("GridPathfinder"),
			NodePath("CapooProjectileMotionSystem"),
			NodePath("CombatRobotDroneMotionSystem"),
			NodePath("EnemySpawnPoints"),
			NodePath("EnemySpawnTimer"),
			NodePath("StateTimer"),
			NodePath("SessionObjectPool"),
			NodePath("BossContainer"),
		]
	)
	_test_packed_scene_structure(
		"TowerDefenseGame",
		TOWER_DEFENSE_GAME_SCENE_PATH,
		&"TowerDefenseGame",
		[
			NodePath("MultiplayerGameplayGateway"),
			NodePath("MultiplayerModeAdapter"),
			NodePath("DayNightController"),
			NodePath("EnemyContainer"),
			NodePath("GridPathfinder"),
			NodePath("CapooProjectileMotionSystem"),
			NodePath("CombatRobotDroneMotionSystem"),
			NodePath("EnemySpawnPoints"),
			NodePath("EnemySpawnTimer"),
			NodePath("StateTimer"),
			NodePath("SessionObjectPool"),
			NodePath("BossContainer"),
			NodePath("HomeGateController"),
			NodePath("PlantContainer"),
			NodePath("PlantSystem"),
			NodePath("DualGridTerrain"),
			NodePath("FateCoordinator"),
		]
	)
	_test_packed_scene_structure(
		"RogueCombatGame",
		ROGUE_COMBAT_SCENE_PATH,
		&"RogueCombatGame01",
		[
			NodePath("MultiplayerGameplayGateway"),
			NodePath("MultiplayerModeAdapter"),
			NodePath("DayNightController"),
			NodePath("EnemyContainer"),
			NodePath("GridPathfinder"),
			NodePath("CapooProjectileMotionSystem"),
			NodePath("CombatRobotDroneMotionSystem"),
			NodePath("EnemySpawnPoints"),
			NodePath("EnemySpawnTimer"),
			NodePath("StateTimer"),
			NodePath("SessionObjectPool"),
			NodePath("CombatDeadlineTimer"),
			NodePath("RogueCombatHUD"),
			NodePath("PlayerLifeStatusLayer/PlayerLifeStatusHUD"),
		]
	)
	_test_packed_scene_structure(
		"RogueRouteGame",
		ROGUE_ROUTE_SCENE_PATH,
		&"RogueRouteGame",
		[
			NodePath("EncounterEconomy"),
			NodePath("EncounterSession"),
			NodePath("SingleplayerCombatCoordinator"),
			NodePath("EncounterScene"),
			NodePath("World/Players"),
			NodePath("CombatVictoryPresentation"),
			NodePath("CombatSceneTransition"),
		]
	)
	_test_packed_scene_structure(
		"MpGame",
		MP_GAME_SCENE_PATH,
		&"MpGame",
		[
			NodePath("SessionCoordinator"),
			NodePath("PlayerCoordinator"),
			NodePath("EnemyCoordinator"),
			NodePath("ProjectileCoordinator"),
			NodePath("WorldFlowCoordinator"),
			NodePath("PublicRoomKeepaliveRequest"),
		]
	)
	_test_packed_scene_structure(
		"MpRogueRoute",
		MP_ROGUE_ROUTE_SCENE_PATH,
		&"MpRogueRoute",
		[
			NodePath("RogueRoute"),
			NodePath("RogueCombatCoordinator"),
		]
	)


func _test_packed_scene_structure(
	label: String,
	path: String,
	expected_root_name: StringName,
	required_paths: Array[NodePath]
) -> void:
	var packed_scene := load(path) as PackedScene
	_expect(packed_scene != null, "无法加载 %s 根场景：%s。" % [label, path])
	if packed_scene == null:
		return
	var instance := packed_scene.instantiate()
	_expect(instance != null, "无法实例化 %s 根场景。" % label)
	if instance == null:
		return
	_expect(instance.name == expected_root_name, "%s 根节点名称改变。" % label)
	for required_path in required_paths:
		_expect(
			instance.get_node_or_null(required_path) != null,
			"%s 关键 NodePath 改变或缺失：%s。" % [label, required_path]
		)
	instance.free()


func _test_rogue_combat_network_path() -> void:
	var route_scene := load(MP_ROGUE_ROUTE_SCENE_PATH) as PackedScene
	if route_scene == null:
		return
	var route_instance := route_scene.instantiate()
	if route_instance == null:
		return
	var coordinator := route_instance.get_node_or_null("RogueCombatCoordinator")
	_expect(coordinator != null, "MpRogueRoute 必须静态保留 RogueCombatCoordinator。")
	if coordinator != null:
		var coordinator_script := coordinator.get_script() as Script
		_expect(
			coordinator_script != null
			and coordinator_script.resource_path
			== ROGUE_COMBAT_COORDINATOR_SOURCE_PATH,
			"RogueCombatCoordinator NodePath 绑定了错误脚本。"
		)
	route_instance.free()

	var source := FileAccess.get_file_as_string(
		ROGUE_COMBAT_COORDINATOR_SOURCE_PATH
	)
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("无法编译 RogueCombatNetwork NodePath 表达式。")
		return
	var compact_source := whitespace_regex.sub(source, "", true)
	_expect(
		compact_source.contains(
			'constCOMBAT_RUNTIME_NODE_NAME:=&"RogueCombatNetwork"'
		),
		"内嵌 MpGame 节点名必须保持 RogueCombatNetwork。"
	)
	_expect(
		compact_source.contains("instance.name=COMBAT_RUNTIME_NODE_NAME")
		and compact_source.contains("_combat_network=instanceadd_child(instance)"),
		"内嵌 MpGame 必须继续作为 RogueCombatCoordinator 的直接子节点创建。"
	)
	_expect(
		ROGUE_COMBAT_NETWORK_PATH
		== NodePath("RogueCombatCoordinator/RogueCombatNetwork"),
		"Rogue 内嵌战斗 RPC NodePath 冻结值改变。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("STAGE5_PROTOCOL_STRUCTURE_FREEZE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
