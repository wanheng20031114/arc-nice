extends SceneTree

const CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const CARDBOARD_SCENE := preload(
	"res://scene/enemy/artificial_creation/cardboard_monster.tscn"
)
const CODEX_ENTRY := preload(
	"res://resources/config/encyclopedia/enemies/cardboard_monster.tres"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_codex_contract()
	_test_registry_and_texture_counts()
	_test_fate_and_wire_boundaries()
	_test_scene_reference()
	_finish()


func _test_codex_contract() -> void:
	_expect(
		CODEX_ENTRY.entry_id == &"cardboard_monster"
		and CODEX_ENTRY.enemy_config == CARDBOARD_CONFIG
		and CODEX_ENTRY.family_id == &"artificial_creation"
		and CODEX_ENTRY.family_label == "人工造物"
		and CODEX_ENTRY.rank == EnemyCodexEntryConfig.Rank.NORMAL
		and CODEX_ENTRY.sort_order == 515
		and CODEX_ENTRY.traits
		== PackedStringArray(["人工造物", "固定承伤1", "纸棒短挥"]),
		"纸箱怪图鉴必须保持515排序与三项玩家可见特性。"
	)
	_expect(
		CARDBOARD_CONFIG.display_name == "纸箱怪"
		and CARDBOARD_CONFIG.category_tags
		== PackedStringArray(["artificial_creation"]),
		"纸箱怪必须只属于人工造物。"
	)
	_expect(
		EnemyCodexRegistry.ENTRY_COUNT == 64
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.NORMAL
		] == 51
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.ELITE
		] == 12
		and EnemyCodexRegistry.EXPECTED_RANK_COUNTS[
			EnemyCodexEntryConfig.Rank.BOSS
		] == 1
		and EnemyCodexRegistry.EXPECTED_FAMILY_COUNTS[&"artificial_creation"] == 4
		and EnemyCodexRegistry.EXPECTED_FAMILY_COUNTS[&"mechanical_life"] == 11
		and EnemyCodexRegistry.validate_contract(),
		"图鉴计数必须为64/51/12/1，人工造物4、机械生命11。"
	)


func _test_registry_and_texture_counts() -> void:
	var enemy_png_count := _count_pngs_recursive(
		"res://resources/texture/enemy"
	)
	var artificial_png_count := _count_pngs_recursive(
		"res://resources/texture/enemy/artificial_creation"
	)
	var mechanical_png_count := _count_pngs_recursive(
		"res://resources/texture/enemy/mechanical_life"
	)
	_expect(
		enemy_png_count == 88
		and artificial_png_count == 4
		and mechanical_png_count == 21,
		"敌人纹理必须为88张，人工造物4张，机械生命21张；实际%d/%d/%d。"
		% [enemy_png_count, artificial_png_count, mechanical_png_count]
	)


func _test_fate_and_wire_boundaries() -> void:
	var mappings := FateCoordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH
	_expect(
		mappings.size() == 10
		and not mappings.has(
			"res://resources/config/enemies/cardboard_monster.tres"
		),
		"命运精英映射必须保持10项，纸箱怪不得拥有精英替换。"
	)
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 86
		and NET_CONSTANTS.CHANNEL_COUNT == 8
		and CombatAttackRegistry.PlayerHitWireId.COMBAT_ROBOT_GUNNER_ELITE_BULLET
		== 18,
		"协议v86必须保留内容摘要、同局成员身份、纸箱怪及既有 wire 合同。"
	)


func _test_scene_reference() -> void:
	var enemy := CARDBOARD_SCENE.instantiate()
	_expect(
		enemy != null
		and CARDBOARD_CONFIG.enemy_scene == CARDBOARD_SCENE,
		"纸箱怪配置必须直接引用其人工造物场景。"
	)
	if enemy != null:
		enemy.free()


func _count_pngs_recursive(directory_path: String) -> int:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法打开纹理目录：%s。" % directory_path)
		return 0
	var count := 0
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				count += _count_pngs_recursive(child_path)
			elif entry_name.get_extension().to_lower() == "png":
				count += 1
		entry_name = directory.get_next()
	directory.list_dir_end()
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("CARDBOARD_MONSTER_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
