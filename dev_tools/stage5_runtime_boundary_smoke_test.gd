extends SceneTree

const COMBAT_RUNTIME_PATH := (
	"res://scene/combat/runtime/combat_runtime_base.gd"
)
const WAVE_RUNTIME_PATH := (
	"res://scene/combat/runtime/wave_combat_runtime_base.gd"
)
const STANDARD_GAME_PATH := (
	"res://scene/game_modes/standard/standard_game.gd"
)
const TOWER_GAME_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const TOWER_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ROGUE_COMBAT_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game.gd"
)
const ROGUE_COMBAT_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const BOSS_RUNTIME_PORT_SCENES := [
	"res://scene/game_modes/standard/boss/standard_linglan_boss_runtime_port.tscn",
	"res://scene/game_modes/tower_defense/boss/tower_defense_linglan_boss_runtime_port.tscn",
]

const MODE_SCENES := {
	"普通模式": "res://scene/game_modes/standard/standard_game.tscn",
	"塔防模式": "res://scene/game_modes/tower_defense/tower_defense_game.tscn",
	"肉鸽作战": "res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
}

const COMBAT_RUNTIME_FORBIDDEN_TOKENS := [
	"PlantDefense",
	"TowerDefense",
	"Luoxi",
	"luoxi",
	"Xiaocong",
	"xiaocong",
	"Linglan",
	"linglan",
	"test_arena",
	"terrain_snapshot",
	"terrain_delta",
	"var wave_state",
	"func _apply_wave_start_lighting",
	"func apply_remote_flow_state",
	"func get_flow_state_snapshot",
	"func apply_remote_boss_started",
	"func apply_remote_defeat",
	"func apply_remote_victory",
	"func apply_remote_enemy_count",
	"func try_purchase_skill1_for_peer",
	"func apply_skill1_purchase_state",
	"func show_local_skill1_purchase_result",
	"func show_debug_collectible_grant_result",
	"func show_simple_crafting_result",
]

const WAVE_RUNTIME_FORBIDDEN_TOKENS := [
	"StandardPlayerProfilePanel",
	"StandardWaveHUD",
	"Zhuangfangyi",
	"Luoxi",
	"Linglan",
	"BossConfig",
	"standard_merchants",
	"return_to_lobby",
	"debug_collectible",
	"TANGO_",
	"request_tango_charge",
]

const TOWER_ROOT_REDUNDANT_FACADES := [
	"func apply_remote_flow_state(",
	"func request_tower_defense_wave_start(",
	"func consume_next_player_respawn_delay(",
	"func request_tango_charge_started(",
	"func _update_wave_music(",
]

var failures := PackedStringArray()


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_runtime_inheritance()
	_test_neutral_combat_runtime_surface()
	_test_neutral_wave_runtime_surface()
	_test_static_mode_boundaries()
	_test_tower_root_is_orchestration_only()
	_test_mode_adapters_fail_closed()
	if failures.is_empty():
		print("STAGE5_RUNTIME_BOUNDARY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_runtime_inheritance() -> void:
	_expect(FileAccess.file_exists(WAVE_RUNTIME_PATH), "缺少 WaveCombatRuntimeBase。")
	_expect(
		_source_has_extends(STANDARD_GAME_PATH, "WaveCombatRuntimeBase"),
		"StandardGame 必须直接继承 WaveCombatRuntimeBase。"
	)
	_expect(
		_source_has_extends(ROGUE_COMBAT_PATH, "WaveCombatRuntimeBase"),
		"RogueCombatGame 必须直接继承 WaveCombatRuntimeBase。"
	)
	_expect(
		not _source_has_extends(ROGUE_COMBAT_PATH, "StandardGame"),
		"肉鸽作战不得继续继承普通模式。"
	)
	var rogue_source := FileAccess.get_file_as_string(ROGUE_COMBAT_PATH)
	var rogue_scene_source := FileAccess.get_file_as_string(ROGUE_COMBAT_SCENE_PATH)
	_expect(
		not rogue_source.contains("standard_merchants_enabled")
		and not rogue_source.contains("linglan_boss_enabled"),
		"肉鸽作战不得依靠普通模式商人或 Boss 开关裁剪继承能力。"
	)
	_expect(
		not rogue_source.contains("StandardPlayerProfilePanel")
		and not rogue_scene_source.contains("game_modes/standard"),
		"肉鸽作战不得反向依赖普通模式 Profile。"
	)
	_expect(
		_source_has_extends(TOWER_GAME_PATH, "CombatRuntimeBase"),
		"TowerDefenseGame 必须直接继承中性 CombatRuntimeBase。"
	)


func _test_neutral_combat_runtime_surface() -> void:
	var source := FileAccess.get_file_as_string(COMBAT_RUNTIME_PATH)
	_expect(not source.is_empty(), "无法读取 CombatRuntimeBase。")
	for forbidden_token in COMBAT_RUNTIME_FORBIDDEN_TOKENS:
		_expect(
			not source.contains(forbidden_token),
			"CombatRuntimeBase 仍包含模式专属标识：%s。" % forbidden_token
		)


func _test_neutral_wave_runtime_surface() -> void:
	var source := FileAccess.get_file_as_string(WAVE_RUNTIME_PATH)
	_expect(not source.is_empty(), "无法读取 WaveCombatRuntimeBase。")
	for forbidden_token in WAVE_RUNTIME_FORBIDDEN_TOKENS:
		_expect(
			not source.contains(forbidden_token),
			"WaveCombatRuntimeBase 仍包含普通模式标识：%s。"
			% forbidden_token
		)
	_expect(
		source.contains("var wave_state"),
		"WaveCombatRuntimeBase 必须拥有波次状态，不能反向依赖 CombatRuntimeBase。"
	)


func _test_static_mode_boundaries() -> void:
	for label_variant in MODE_SCENES:
		var label := str(label_variant)
		var scene_path := str(MODE_SCENES[label_variant])
		var packed_scene := load(scene_path) as PackedScene
		_expect(packed_scene != null, "%s 场景无法加载。" % label)
		if packed_scene == null:
			continue
		var instance := packed_scene.instantiate()
		_expect(instance != null, "%s 场景无法实例化。" % label)
		if instance == null:
			continue
		_expect(
			instance.get_node_or_null("MultiplayerGameplayGateway")
				is MultiplayerGameplayGateway,
			"%s 必须静态搭建 MultiplayerGameplayGateway。" % label
		)
		_expect(
			instance.get_node_or_null("MultiplayerModeAdapter")
				is MultiplayerModeAdapter,
			"%s 必须静态搭建专属 MultiplayerModeAdapter。" % label
		)
		instance.free()
	for scene_path in BOSS_RUNTIME_PORT_SCENES:
		var first_line := FileAccess.get_file_as_string(scene_path).get_slice("\n", 0)
		_expect(
			first_line.contains(" uid=\"uid://"),
			"静态 Boss runtime port 场景必须声明稳定 UID：%s。" % scene_path
		)


func _test_tower_root_is_orchestration_only() -> void:
	var root_source := FileAccess.get_file_as_string(TOWER_GAME_PATH)
	var scene_source := FileAccess.get_file_as_string(TOWER_SCENE_PATH)
	for redundant_facade in TOWER_ROOT_REDUNDANT_FACADES:
		_expect(
			not root_source.contains(redundant_facade),
			"TowerDefenseGame 仍保留重复转发：%s。" % redundant_facade
		)
	for authored_connection in [
		'signal="player_runtime_binding_requested" from="PlayerRosterCoordinator"',
		'signal="enemy_retarget_requested" from="PlayerRosterCoordinator"',
		'signal="personal_inventory_output_committed" from="ProductionCoordinator"',
		'signal="research_state_changed" from="ResearchCoordinator"',
	]:
		_expect(
			scene_source.contains(authored_connection),
			"塔防场景缺少静态信号连接：%s。" % authored_connection
		)


func _test_mode_adapters_fail_closed() -> void:
	var default_adapter := MultiplayerModeAdapter.new()
	_expect(
		not default_adapter.accepts_game_mode_id(GameModeCatalog.MODE_STANDARD),
		"中性 MultiplayerModeAdapter 不得接纳任何生产模式。"
	)
	_expect(
		default_adapter.try_purchase_skill1_for_peer(1)
			== MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER,
		"未绑定模式的技能购买必须 fail-closed，不能返回成功码。"
	)
	default_adapter.free()

	var standard_adapter := StandardMultiplayerModeAdapter.new()
	_expect(
		standard_adapter.accepts_game_mode_id(GameModeCatalog.MODE_STANDARD)
		and not standard_adapter.accepts_game_mode_id(
			GameModeCatalog.MODE_TOWER_DEFENSE
		),
		"普通模式适配器只能接纳普通模式 wire id。"
	)
	standard_adapter.free()

	var rogue_adapter := RogueMultiplayerModeAdapter.new()
	_expect(
		rogue_adapter.accepts_game_mode_id(GameModeCatalog.MODE_TEST_ARENA_P3)
		and not rogue_adapter.accepts_game_mode_id(
			GameModeCatalog.MODE_STANDARD
		),
		"肉鸽适配器只能接纳冻结 wire id 4。"
	)
	rogue_adapter.free()

	var tower_adapter := TowerDefenseMultiplayerModeAdapter.new()
	for tower_mode_id in [
		GameModeCatalog.MODE_TOWER_DEFENSE,
		GameModeCatalog.MODE_TEST_ARENA_P1,
		GameModeCatalog.MODE_TEST_ARENA_P2,
		GameModeCatalog.MODE_TEST_ARENA_P1B,
	]:
		_expect(
			tower_adapter.accepts_game_mode_id(tower_mode_id),
			"塔防适配器必须接纳塔防及 P1/P2/P1B 测试场 wire id。"
		)
	_expect(
		not tower_adapter.accepts_game_mode_id(
			GameModeCatalog.MODE_TEST_ARENA_P3
		),
		"塔防适配器不得接纳肉鸽 wire id 4。"
	)
	tower_adapter.free()


func _source_has_extends(path: String, base_name: String) -> bool:
	var source := FileAccess.get_file_as_string(path)
	var extends_regex := RegEx.new()
	if extends_regex.compile("(?m)^extends\\s+%s\\s*$" % base_name) != OK:
		return false
	return extends_regex.search(source) != null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
