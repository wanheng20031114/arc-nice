extends SceneTree

const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator_elite.tres"
)
const ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator_elite.tscn"
)
const ELITE_DRONE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn"
)
const OPERATOR_FRAMES := preload(
	"res://resources/animation/combat_robot_drone_operator_elite.tres"
)
const DRONE_FRAMES := preload(
	"res://resources/animation/combat_robot_suicide_drone_elite.tres"
)
const CODEX_ENTRY := preload(
	"res://resources/config/encyclopedia/enemies/combat_robot_drone_operator_elite.tres"
)
const DEFAULT_DROP_TABLE := preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const FATE_COORDINATOR_SCRIPT := preload(
	"res://scene/game_modes/tower_defense/fate/fate_coordinator.gd"
)
const P1B_WAVE_PATHS := [
	"res://resources/config/campaigns/test_arena/p1b/singleplayer/wave_01.tres",
	"res://resources/config/campaigns/test_arena/p1b/multiplayer/wave_01.tres",
]
const P1B_EXPECTED_ENTRY_ORDER := [
	"SubResource(\"Resource_combat_robot_entry\")",
	"SubResource(\"Resource_combat_robot_gunner_entry\")",
	"SubResource(\"Resource_combat_robot_drone_operator_entry\")",
	"SubResource(\"Resource_combat_robot_shield_bearer_entry\")",
	"SubResource(\"Resource_combat_robot_ninja_entry\")",
]
const ELITE_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot_drone_operator_elite.tres"
)
const ZERO_DIRECT_REFERENCE_ROOTS := {
	"正式标准单人波次": "res://resources/config/campaigns/standard/singleplayer",
	"正式标准多人波次": "res://resources/config/campaigns/standard/multiplayer",
	"正式塔防波次": "res://resources/config/campaigns/tower_defense/formal",
	"旧正式波次": "res://resources/config/waves",
	"肉鸽战斗波次": "res://resources/config/campaigns/rogue_combat",
	"肉鸽遭遇配置": "res://resources/config/rogue_combat",
	"P1B单人": "res://resources/config/campaigns/test_arena/p1b/singleplayer",
	"P1B多人": "res://resources/config/campaigns/test_arena/p1b/multiplayer",
}
const TEXTURE_CONTRACTS := {
	"res://resources/texture/enemy/mechanical_life/combat_robot_drone_operator_elite.png": {
		"size": Vector2i(256, 96),
		"sha256": "ec9fdb615610531e24350237cd8aa9556909ba135acae15d53624d0fd9221bd0",
	},
	"res://resources/texture/enemy/mechanical_life/combat_robot_suicide_drone_elite.png": {
		"size": Vector2i(64, 16),
		"sha256": "6e3190f928bc5d49fa654bba1f9edd2ee6e071e4d9d21420a8b8a7256fb94c0d",
	},
	"res://resources/texture/enemy/mechanical_life/combat_robot_drone_target_marker_elite.png": {
		"size": Vector2i(64, 16),
		"sha256": "8be355f9b24d7920b5cb350addd9af289b698e7c672f39ff7db5e77f19d6d747",
	},
	"res://resources/texture/enemy/mechanical_life/combat_robot_mechanical_explosion_elite.png": {
		"size": Vector2i(512, 64),
		"sha256": "c3e2ba275b9151a897b8f0411c59dd7acd9ebc0e37e26bc242e960a13ea571b1",
	},
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_texture_and_animation_contract()
	_test_config_scene_and_codex_contract()
	_test_registry_and_fate_contract()
	_test_p1b_contract()
	_test_zero_direct_references()
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_DRONE_OPERATOR_ELITE_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_texture_and_animation_contract() -> void:
	for texture_path: String in TEXTURE_CONTRACTS:
		var contract: Dictionary = TEXTURE_CONTRACTS[texture_path]
		var texture := load(texture_path) as Texture2D
		_expect(texture != null, "精英操作员运行纹理必须可读取：%s。" % texture_path)
		if texture == null:
			continue
		_expect(
			Vector2i(texture.get_size()) == contract["size"],
			"精英操作员运行纹理尺寸不正确：%s。" % texture_path
		)
		_expect(
			_sha256_file(texture_path) == contract["sha256"],
			"精英操作员运行纹理SHA-256漂移：%s。" % texture_path
		)

	_expect_animation(OPERATOR_FRAMES, &"move", 8, 14.0, true)
	_expect_animation(OPERATOR_FRAMES, &"deploy", 3, 30.0, false)
	_expect_animation(OPERATOR_FRAMES, &"death", 8, 12.0, false)
	_expect_animation(DRONE_FRAMES, &"fly", 4, 12.0, true)
	_expect_animation(DRONE_FRAMES, &"target", 4, 12.0, true)
	_expect_animation(DRONE_FRAMES, &"explode", 8, 14.0, false)


func _test_config_scene_and_codex_contract() -> void:
	_expect(
		ELITE_CONFIG is CombatRobotDroneOperatorEliteConfig
		and ELITE_CONFIG is CombatRobotDroneOperatorConfig,
		"精英操作员必须以独立配置类复用普通操作员合同。"
	)
	_expect(ELITE_CONFIG.display_name == "精英爆炸无人机操作员", "精英操作员显示名不正确。")
	_expect(ELITE_CONFIG.enemy_scene == ELITE_SCENE, "精英操作员必须绑定独立场景。")
	_expect(ELITE_CONFIG.drone_scene == ELITE_DRONE_SCENE, "精英操作员必须绑定独立紫能无人机场景。")
	_expect(
		ELITE_CONFIG.max_health == 360
		and ELITE_CONFIG.attack_damage == 100
		and ELITE_CONFIG.physical_defense == 20
		and ELITE_CONFIG.magic_defense == 15
		and is_equal_approx(ELITE_CONFIG.move_speed, 40.0)
		and ELITE_CONFIG.home_damage == 2
		and ELITE_CONFIG.xirang_kill_reward == 10,
		"精英操作员核心属性必须保持360/100/20/15/40/2/10。"
	)
	_expect(
		is_equal_approx(ELITE_CONFIG.attack_range, 80.0)
		and is_equal_approx(ELITE_CONFIG.stop_distance, 40.0)
		and is_equal_approx(ELITE_CONFIG.deploy_delay, 0.10)
		and is_equal_approx(ELITE_CONFIG.attack_cooldown, 2.5)
		and is_equal_approx(ELITE_CONFIG.drone_speed, 90.0)
		and is_equal_approx(ELITE_CONFIG.explosion_radius, 28.0)
		and ELITE_CONFIG.projectile_type == &"combat_robot_suicide_drone_elite",
		"精英操作员部署参数必须保持80/40/0.10/2.5/90/28与独立类型。"
	)
	_expect(ELITE_CONFIG.drop_table == DEFAULT_DROP_TABLE, "精英操作员必须沿用通用掉落表。")
	_expect(
		ELITE_CONFIG.category_tags == PackedStringArray(["mechanical_life"]),
		"精英操作员必须仅属于机械生命。"
	)

	var enemy := ELITE_SCENE.instantiate() as CombatRobotDroneOperator
	_expect(enemy != null, "精英操作员场景必须实例化CombatRobotDroneOperator。")
	if enemy != null:
		var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		_expect(
			sprite != null and sprite.sprite_frames == OPERATOR_FRAMES,
			"精英操作员场景必须直接绑定批准的独立SpriteFrames。"
		)
		enemy.free()
	var drone := ELITE_DRONE_SCENE.instantiate() as CombatRobotSuicideDrone
	_expect(drone != null, "精英紫能无人机场景必须复用批量无人机类型。")
	if drone != null:
		_expect(
			drone.authored_source_type == &"combat_robot_suicide_drone_elite",
			"精英无人机必须保留独立来源类型。"
		)
		drone.free()

	_expect(
		CODEX_ENTRY.entry_id == &"combat_robot_drone_operator_elite"
		and CODEX_ENTRY.enemy_config == ELITE_CONFIG
		and CODEX_ENTRY.family_id == &"mechanical_life"
		and CODEX_ENTRY.rank == EnemyCodexEntryConfig.Rank.ELITE
		and CODEX_ENTRY.sort_order == 545
		and CODEX_ENTRY.traits == PackedStringArray(["精英", "紫能投送", "高速无人机"])
		and CODEX_ENTRY.description.contains("90")
		and CODEX_ENTRY.description.contains("落点不会改变")
		and CODEX_ENTRY.description.contains("离开标记范围"),
		"精英操作员图鉴必须说明紫能高速投送、固定落点与离开标记躲避。"
	)


func _test_registry_and_fate_contract() -> void:
	var registry_text := FileAccess.get_file_as_string(
		"res://resources/config/encyclopedia/enemy_codex_registry.gd"
	)
	var catalog_text := FileAccess.get_file_as_string(
		"res://resources/config/encyclopedia/codex_catalog.gd"
	)
	_expect(
		registry_text.contains("const ENTRY_COUNT := 64")
		and registry_text.contains("&\"mechanical_life\": 11")
		and registry_text.contains("EnemyCodexEntryConfig.Rank.NORMAL: 51")
		and registry_text.contains("EnemyCodexEntryConfig.Rank.ELITE: 12")
		and registry_text.contains("EnemyCodexEntryConfig.Rank.BOSS: 1")
		and registry_text.count(
			"resources/config/encyclopedia/enemies/combat_robot_drone_operator_elite.tres"
		) == 1
		and catalog_text.contains("CodexSection.ENEMY: 64"),
		"图鉴计数必须保持64总数、51普通、12精英、1 Boss、11机械生命。"
	)

	var fate_coordinator := FATE_COORDINATOR_SCRIPT.new()
	_expect(
		fate_coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.size() == 10
		and str(fate_coordinator.ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.get(
			"res://resources/config/enemies/combat_robot_drone_operator.tres",
			""
		)) == ELITE_CONFIG_PATH,
		"命运系统必须把普通操作员映射到精英操作员，并保持十组替换。"
	)
	fate_coordinator.free()


func _test_p1b_contract() -> void:
	for wave_path in P1B_WAVE_PATHS:
		var wave_text := FileAccess.get_file_as_string(wave_path)
		_expect(
			not wave_text.is_empty()
			and wave_text.count("count = 200") == 5
			and wave_text.contains("spawn_order = 1")
			and wave_text.contains("spawn_interval = 3.0")
			and wave_text.contains("max_alive_enemies = 1000"),
			"P1B必须保持五型机器人各200台、总数1000与严格轮转。"
		)
		var entries_line := ""
		for line in wave_text.split("\n"):
			if line.begins_with("enemy_entries = "):
				entries_line = line
				break
		var previous_index := -1
		for entry_token in P1B_EXPECTED_ENTRY_ORDER:
			var current_index := entries_line.find(entry_token)
			_expect(
				current_index > previous_index,
				"P1B五型机器人必须保持持剑、持枪、操作员、举盾、忍者顺序。"
			)
			previous_index = current_index


func _test_zero_direct_references() -> void:
	for label: String in ZERO_DIRECT_REFERENCE_ROOTS:
		var directory_path: String = ZERO_DIRECT_REFERENCE_ROOTS[label]
		var references := _find_text_references(directory_path, ELITE_CONFIG_PATH)
		_expect(
			references.is_empty(),
			"%s不得直接引用精英爆炸无人机操作员：%s。" % [label, references]
		)


func _find_text_references(directory_path: String, needle: String) -> Array[String]:
	var matches: Array[String] = []
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法打开集成审计目录：%s。" % directory_path)
		return matches
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				matches.append_array(_find_text_references(child_path, needle))
			elif entry_name.get_extension() in ["tres", "tscn", "gd"]:
				var file := FileAccess.open(child_path, FileAccess.READ)
				if file != null and needle in file.get_as_text():
					matches.append(child_path)
		entry_name = directory.get_next()
	directory.list_dir_end()
	return matches


func _expect_animation(
	frames: SpriteFrames,
	animation_name: StringName,
	frame_count: int,
	speed: float,
	loops: bool
) -> void:
	_expect(frames.has_animation(animation_name), "缺少%s动画。" % animation_name)
	if not frames.has_animation(animation_name):
		return
	_expect(
		frames.get_frame_count(animation_name) == frame_count
		and is_equal_approx(frames.get_animation_speed(animation_name), speed)
		and frames.get_animation_loop(animation_name) == loops,
		"%s动画帧数、帧率或循环合同不正确。" % animation_name
	)


func _sha256_file(resource_path: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(resource_path)
	if bytes.is_empty():
		return ""
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		return ""
	hashing.update(bytes)
	return hashing.finish().hex_encode()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
