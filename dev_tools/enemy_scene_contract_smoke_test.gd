extends SceneTree

const ENEMY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/yuanshi_insect_basic.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fast.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_purple_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_green_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_guardian.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"),
	preload("res://resources/config/enemies/capoo_ak47.tres"),
	preload("res://resources/config/enemies/capoo_knight.tres"),
	preload("res://resources/config/enemies/capoo_knight_elite.tres"),
	preload("res://resources/config/enemies/capoo_swordsman.tres"),
	preload("res://resources/config/enemies/capoo_rpg.tres"),
	preload("res://resources/config/enemies/capoo_mage.tres"),
	preload("res://resources/config/enemies/capoo_sniper.tres"),
	preload("res://resources/config/enemies/capoo_smg.tres"),
	preload("res://resources/config/enemies/stone_golem.tres"),
	preload("res://resources/config/enemies/stone_golem_elite.tres"),
	preload("res://resources/config/enemies/fire_sorcerer.tres"),
	preload("res://resources/config/enemies/fire_sorcerer_elite.tres"),
	preload("res://resources/config/enemies/frost_sorcerer.tres"),
	preload("res://resources/config/enemies/frost_sorcerer_elite.tres"),
	preload("res://resources/config/enemies/lightning_sorcerer.tres"),
	preload("res://resources/config/enemies/slime.tres"),
	preload("res://resources/config/enemies/slime_golden.tres"),
	preload("res://resources/config/enemies/slime_fire.tres"),
	preload("res://resources/config/enemies/slime_frost.tres"),
	preload("res://resources/config/enemies/slime_green.tres"),
]
const STANDARD_YUANSHI_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/yuanshi_insect_basic.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fast.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"),
]
const ADVANCED_YUANSHI_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/yuanshi_insect_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_purple_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_green_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_guardian.tres"),
]
const YUANSHI_CATEGORY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/yuanshi_insect_basic.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fast.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_purple_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_green_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_guardian.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"),
]
const CAPOO_CATEGORY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/capoo_ak47.tres"),
	preload("res://resources/config/enemies/capoo_knight.tres"),
	preload("res://resources/config/enemies/capoo_knight_elite.tres"),
	preload("res://resources/config/enemies/capoo_swordsman.tres"),
	preload("res://resources/config/enemies/capoo_rpg.tres"),
	preload("res://resources/config/enemies/capoo_mage.tres"),
	preload("res://resources/config/enemies/capoo_sniper.tres"),
	preload("res://resources/config/enemies/capoo_smg.tres"),
]
const SORCERER_CATEGORY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/fire_sorcerer.tres"),
	preload("res://resources/config/enemies/fire_sorcerer_elite.tres"),
	preload("res://resources/config/enemies/frost_sorcerer.tres"),
	preload("res://resources/config/enemies/frost_sorcerer_elite.tres"),
	preload("res://resources/config/enemies/lightning_sorcerer.tres"),
]
const ARTIFICIAL_CREATION_CATEGORY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/stone_golem.tres"),
	preload("res://resources/config/enemies/stone_golem_elite.tres"),
]
const SLIME_CATEGORY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/slime.tres"),
	preload("res://resources/config/enemies/slime_golden.tres"),
	preload("res://resources/config/enemies/slime_fire.tres"),
	preload("res://resources/config/enemies/slime_frost.tres"),
	preload("res://resources/config/enemies/slime_green.tres"),
]
const DEFAULT_ENEMY_DROP_TABLE: EnemyDropTable = preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const LINGLAN_BOSS_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/linglan_boss.tres"
)
const ENEMY_VISUAL_SHADER_PATH := "res://scene/entity_motion_status.gdshader"
const PLAYER_BULLET_SCENE := preload("res://scene/bullet.tscn")
const CAPOO_AK47_BULLET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn"
)
const CAPOO_SMG_BULLET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_smg_bullet.tscn"
)
const PLAYER_COLLISION_LAYER := 1 << 1
const ENEMY_BODY_COLLISION_LAYER := 1 << 2
const BULLET_COLLISION_LAYER := 1 << 4
const PLANT_BODY_COLLISION_LAYER := 1 << 9
const PLAYER_BODY_VISUAL_Z_INDEX := 1
const ENEMY_BODY_VISUAL_Z_INDEX := 2

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "EnemySceneContractSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_yuanshi_xirang_reward_tiers()
	_test_enemy_drop_and_category_contract()
	for enemy_config in ENEMY_CONFIGS:
		await _test_enemy_scene_contract(enemy_config)
	_test_enemy_projectile_z_contract()
	await _test_player_bullet_body_hit_path()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("ENEMY_SCENE_CONTRACT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_enemy_projectile_z_contract() -> void:
	for projectile_scene in [
		CAPOO_AK47_BULLET_SCENE,
		CAPOO_SMG_BULLET_SCENE,
	]:
		var projectile := projectile_scene.instantiate() as Area2D
		_expect(
			projectile != null
			and projectile.z_index == 3
			and projectile.z_index > ENEMY_BODY_VISUAL_Z_INDEX,
			"AK与SMG弹体必须使用z=3，严格位于普通敌人身体z=2之上。"
		)
		if projectile != null:
			projectile.free()


func _test_yuanshi_xirang_reward_tiers() -> void:
	for enemy_config in STANDARD_YUANSHI_CONFIGS:
		_expect(
			enemy_config.xirang_kill_reward == 1,
			"%s must grant one Xirang per kill." % enemy_config.display_name
		)
	for enemy_config in ADVANCED_YUANSHI_CONFIGS:
		_expect(
			enemy_config.xirang_kill_reward == 2,
			"%s must grant two Xirang per kill." % enemy_config.display_name
		)


func _test_enemy_drop_and_category_contract() -> void:
	var default_config := EnemyConfig.new()
	var all_drop_configs: Array[EnemyConfig] = ENEMY_CONFIGS.duplicate()
	all_drop_configs.append(LINGLAN_BOSS_CONFIG)
	var expected_config_paths: Array[String] = []
	for enemy_config in all_drop_configs:
		expected_config_paths.append(enemy_config.resource_path)
	expected_config_paths.sort()
	var discovered_config_paths := _get_authored_enemy_config_paths()
	_expect(
		discovered_config_paths == expected_config_paths,
		"The drop-contract audit must dynamically cover every authored EnemyConfig resource."
	)
	_expect(
		default_config.drop_table == DEFAULT_ENEMY_DROP_TABLE,
		"New enemy configs must inherit the shared data-driven drop table."
	)
	_expect(
		all_drop_configs.size() == ENEMY_CONFIGS.size() + 1,
		"The drop-contract audit must cover every regular enemy config plus Linglan."
	)

	var expected_paths: Array[String] = [
		"res://resources/config/materials/material_wood.tres",
		"res://resources/config/materials/material_white_crystal.tres",
		"res://resources/config/materials/material_sapling.tres",
		"res://resources/config/materials/material_capoo_blue_crystal.tres",
		"res://resources/config/materials/material_sorcerer_violet_powder.tres",
		"res://resources/config/pickups/pickup_speed.tres",
		"res://resources/config/pickups/pickup_rapid.tres",
		"res://resources/config/pickups/pickup_tenpura.tres",
		"res://resources/config/pickups/pickup_health.tres",
		"res://resources/config/pickups/pickup_spiral.tres",
	]
	var expected_chances: Array[float] = [
		0.02,
		0.002,
		0.01,
		0.01,
		# 紫粉未指定概率；暂按同为标签专属素材的蓝晶 1% 配置。
		0.01,
		0.004,
		0.004,
		0.004,
		0.004,
		0.002,
	]
	var expected_tags: Array[PackedStringArray] = [
		PackedStringArray(),
		PackedStringArray(),
		PackedStringArray(),
		PackedStringArray(["capoo"]),
		PackedStringArray(["sorcerer"]),
		PackedStringArray(),
		PackedStringArray(),
		PackedStringArray(),
		PackedStringArray(),
		PackedStringArray(),
	]
	_expect(
		DEFAULT_ENEMY_DROP_TABLE.rules.size() == expected_paths.size(),
		"The shared enemy drop table must contain exactly ten independent rules."
	)
	for index in range(
		mini(DEFAULT_ENEMY_DROP_TABLE.rules.size(), expected_paths.size())
	):
		var rule := DEFAULT_ENEMY_DROP_TABLE.rules[index]
		_expect(
			rule != null and rule.pickup_config != null,
			"Default enemy drop rule %d must reference a pickup config." % index
		)
		if rule == null or rule.pickup_config == null:
			continue
		_expect(
			rule.pickup_config.resource_path == expected_paths[index],
			"Default enemy drop rule %d must keep its exact configured item path."
			% index
		)
		_expect(
			is_equal_approx(rule.chance, expected_chances[index]),
			"Default enemy drop rule %d must keep its exact independent probability."
			% index
		)
		_expect(
			rule.required_tags == expected_tags[index],
			"Default enemy drop rule %d must keep its exact tag filter." % index
		)

	var category_counts := {
		"yuanshi_insect": 0,
		"capoo": 0,
		"sorcerer": 0,
		"artificial_creation": 0,
		"slime": 0,
	}
	for enemy_config in all_drop_configs:
		_expect(
			enemy_config.drop_table == DEFAULT_ENEMY_DROP_TABLE,
			"%s must inherit the complete shared table so global drops cannot be removed."
			% enemy_config.resource_path
		)
		for category_tag in enemy_config.category_tags:
			_expect(
				category_counts.has(category_tag),
				"%s must not introduce an unrecognized enemy category tag."
				% enemy_config.resource_path
			)
			if category_counts.has(category_tag):
				category_counts[category_tag] = int(category_counts[category_tag]) + 1
		if enemy_config == LINGLAN_BOSS_CONFIG:
			_expect(
				enemy_config.category_tags.is_empty(),
				"Linglan must remain outside the five regular enemy categories."
			)
		else:
			_expect(
				enemy_config.category_tags.size() == 1,
				"%s must carry exactly one regular enemy category tag."
				% enemy_config.resource_path
			)
	_expect(
		int(category_counts["yuanshi_insect"]) == 8,
		"Exactly the eight Yuanshi insect configs must carry the yuanshi_insect category tag."
	)
	_expect(
		int(category_counts["capoo"]) == 8,
		"Exactly the eight Capoo configs must carry the capoo category tag."
	)
	_expect(
		int(category_counts["sorcerer"]) == 5,
		"Exactly the five fire, frost, and lightning configs must carry the sorcerer category tag."
	)
	_expect(
		int(category_counts["artificial_creation"]) == 2,
		"Exactly the two stone golem configs must carry the artificial_creation category tag."
	)
	_expect(
		int(category_counts["slime"]) == 5,
		"Exactly the five Slime configs must carry the slime category tag."
	)
	_expect_exact_category(YUANSHI_CATEGORY_CONFIGS, "yuanshi_insect")
	_expect_exact_category(CAPOO_CATEGORY_CONFIGS, "capoo")
	_expect_exact_category(SORCERER_CATEGORY_CONFIGS, "sorcerer")
	_expect_exact_category(
		ARTIFICIAL_CREATION_CATEGORY_CONFIGS,
		"artificial_creation"
	)
	_expect_exact_category(SLIME_CATEGORY_CONFIGS, "slime")


func _expect_exact_category(
	enemy_configs: Array[EnemyConfig],
	expected_tag: String
) -> void:
	var expected_tags := PackedStringArray([expected_tag])
	for enemy_config in enemy_configs:
		_expect(
			enemy_config.category_tags == expected_tags,
			"%s must carry only the %s category tag."
			% [enemy_config.resource_path, expected_tag]
		)


func _get_authored_enemy_config_paths() -> Array[String]:
	var config_paths: Array[String] = []
	for file_name in DirAccess.get_files_at(
		"res://resources/config/enemies"
	):
		if not file_name.ends_with(".tres"):
			continue
		var resource_path := (
			"res://resources/config/enemies/" + file_name
		)
		if load(resource_path) is EnemyConfig:
			config_paths.append(resource_path)
	config_paths.sort()
	return config_paths


func _test_enemy_scene_contract(enemy_config: EnemyConfig) -> void:
	_expect(enemy_config != null, "Enemy config must not be null.")
	if enemy_config == null:
		return
	_expect(enemy_config.enemy_scene != null, "%s must provide enemy_scene." % enemy_config.resource_path)
	if enemy_config.enemy_scene == null:
		return

	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "%s scene must instantiate Enemy." % enemy_config.resource_path)
	if enemy == null:
		return

	var animated_sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var touch_damage_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	var legacy_hit_particles := enemy.get_node_or_null("HitParticles") as GPUParticles2D
	var resident_speed_trail := enemy.get_node_or_null("MoveSpeedTrailEffect")
	var body_shape_nodes := _collect_direct_collision_shapes(enemy)
	var touch_shape_nodes := _collect_direct_collision_shapes(touch_damage_area)
	_expect(animated_sprite != null, "%s scene must include AnimatedSprite2D." % enemy_config.resource_path)
	_expect(
		animated_sprite != null
		and animated_sprite.z_index == ENEMY_BODY_VISUAL_Z_INDEX
		and animated_sprite.z_index > PLAYER_BODY_VISUAL_Z_INDEX,
		"%s enemy body must use z=2, explicitly above player body z=1 without overtaking z=4 projectiles."
		% enemy_config.resource_path
	)
	_expect(touch_damage_area != null, "%s scene must include TouchDamageArea." % enemy_config.resource_path)
	_expect(
		(enemy.collision_layer & ENEMY_BODY_COLLISION_LAYER) != 0,
		"%s body must remain directly detectable by player projectiles."
		% enemy_config.resource_path
	)
	_expect(
		touch_damage_area != null
		and (touch_damage_area.collision_mask & BULLET_COLLISION_LAYER) == 0
		and touch_damage_area.collision_mask
			== (PLAYER_COLLISION_LAYER | PLANT_BODY_COLLISION_LAYER),
		"%s TouchDamageArea must monitor only players and plants, not duplicate bullet hits."
		% enemy_config.resource_path
	)
	_expect(
		legacy_hit_particles == null,
		"%s must use the shared hit-effect pool instead of a resident emitter."
		% enemy_config.resource_path
	)
	_expect(
		resident_speed_trail == null,
		"%s must lease speed-trail particles only while hasted instead of carrying four idle emitters."
		% enemy_config.resource_path
	)
	_expect(not body_shape_nodes.is_empty(), "%s scene must include body CollisionShape2D nodes." % enemy_config.resource_path)
	_expect(not touch_shape_nodes.is_empty(), "%s scene must include touch CollisionShape2D nodes." % enemy_config.resource_path)
	if animated_sprite == null or touch_damage_area == null or body_shape_nodes.is_empty() or touch_shape_nodes.is_empty():
		enemy.free()
		return

	var scene_frames := animated_sprite.sprite_frames
	var sprite_material := animated_sprite.material as ShaderMaterial
	var body_shapes := _get_shape_resources(body_shape_nodes)
	var touch_shapes := _get_shape_resources(touch_shape_nodes)
	_expect(enemy.material == null, "%s root node must not hold the enemy visual material." % enemy_config.resource_path)
	_expect(not animated_sprite.use_parent_material, "%s sprite must not inherit a root material." % enemy_config.resource_path)
	_expect(sprite_material != null, "%s sprite must own a ShaderMaterial." % enemy_config.resource_path)
	_expect(
		sprite_material != null and sprite_material.shader.resource_path == ENEMY_VISUAL_SHADER_PATH,
		"%s sprite must use the enemy visual shader." % enemy_config.resource_path
	)
	_expect(
		sprite_material != null and not sprite_material.resource_local_to_scene,
		"%s enemy visual material must be shared for 2D batching." % enemy_config.resource_path
	)
	_expect(scene_frames != null, "%s scene must own SpriteFrames." % enemy_config.resource_path)
	if scene_frames != null:
		_expect(scene_frames.has_animation(enemy_config.move_animation_name), "%s scene must include move animation." % enemy_config.resource_path)
	_expect(animated_sprite.animation == enemy_config.move_animation_name, "%s editor animation must be move." % enemy_config.resource_path)
	_expect(animated_sprite.frame == 0, "%s editor frame must be 0." % enemy_config.resource_path)
	_expect(body_shapes.size() == body_shape_nodes.size(), "%s all body shapes must be configured in scene." % enemy_config.resource_path)
	_expect(touch_shapes.size() == touch_shape_nodes.size(), "%s all touch shapes must be configured in scene." % enemy_config.resource_path)
	_expect(
		_are_body_and_touch_shapes_independent(body_shapes, touch_shapes),
		"%s body and touch shapes must be independently editable." % enemy_config.resource_path
	)

	test_root.add_child(enemy)
	enemy.setup(enemy_config, null, null)
	await process_frame
	_expect(
		touch_damage_area.area_entered.get_connections().is_empty(),
		"%s TouchDamageArea must not register the redundant enemy-side bullet callback."
		% enemy_config.resource_path
	)
	var effects_before := _collect_active_hit_effects().size()
	enemy.call("_play_hit_particles", Vector2.RIGHT)
	var active_effects := _collect_active_hit_effects()
	_expect(
		active_effects.size() == effects_before + 1
		and active_effects.back().emitting,
		"%s hit feedback must use a transient shared effect."
		% enemy_config.resource_path
	)
	if not active_effects.is_empty():
		active_effects.back().call("_on_finished")
	await process_frame

	_expect(animated_sprite.sprite_frames == scene_frames, "%s setup must not replace scene SpriteFrames." % enemy_config.resource_path)
	_expect(enemy.body_collision_shapes.size() == body_shape_nodes.size(), "%s runtime must cache all body collision shapes." % enemy_config.resource_path)
	_expect(enemy.touch_damage_shapes.size() == touch_shape_nodes.size(), "%s runtime must cache all touch collision shapes." % enemy_config.resource_path)
	_expect(_shape_nodes_match_resources(body_shape_nodes, body_shapes), "%s setup must not replace body shapes." % enemy_config.resource_path)
	_expect(_shape_nodes_match_resources(touch_shape_nodes, touch_shapes), "%s setup must not replace touch shapes." % enemy_config.resource_path)
	_test_collision_shapes_mirror_with_facing(enemy_config, enemy, animated_sprite, body_shape_nodes, touch_shape_nodes)

	enemy.play_multiplayer_death_sequence()
	_expect(
		not enemy.is_physics_processing(),
		"%s multiplayer death sequence must stop script physics while its animation finishes."
		% enemy_config.resource_path
	)

	enemy.queue_free()
	await process_frame


func _test_player_bullet_body_hit_path() -> void:
	var enemy := ENEMY_CONFIGS[0].enemy_scene.instantiate() as Enemy
	var bullet := PLAYER_BULLET_SCENE.instantiate() as Bullet
	_expect(enemy != null and bullet != null, "Player bullet collision fixture must instantiate.")
	if enemy == null or bullet == null:
		return
	test_root.add_child(enemy)
	enemy.setup(ENEMY_CONFIGS[0], null, null)
	enemy.set_physics_process(false)
	enemy.global_position = Vector2.ZERO
	var starting_health := enemy.current_health
	bullet.speed = 0.0
	bullet.global_position = enemy.global_position
	test_root.add_child(bullet)
	bullet.setup(Vector2.RIGHT, 5)
	await physics_frame
	await physics_frame
	_expect(
		enemy.current_health == starting_health - 5,
		"Player Bullet.body_entered must own the one authoritative hit after enemy-side area listening is removed."
	)
	if is_instance_valid(bullet):
		bullet.queue_free()
	enemy.queue_free()
	await process_frame


func _collect_active_hit_effects() -> Array[BulletHitEffect]:
	var effects: Array[BulletHitEffect] = []
	for child in test_root.get_children():
		var effect := child as BulletHitEffect
		if effect != null and effect.pool_active:
			effects.append(effect)
	return effects


func _collect_direct_collision_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	if parent_node == null:
		return shapes
	for child in parent_node.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node != null:
			shapes.append(shape_node)
	return shapes


func _get_shape_resources(shape_nodes: Array[CollisionShape2D]) -> Array[Shape2D]:
	var shapes: Array[Shape2D] = []
	for shape_node in shape_nodes:
		if shape_node.shape != null:
			shapes.append(shape_node.shape)
	return shapes


func _are_body_and_touch_shapes_independent(
	body_shapes: Array[Shape2D],
	touch_shapes: Array[Shape2D]
) -> bool:
	for body_shape in body_shapes:
		for touch_shape in touch_shapes:
			if body_shape == touch_shape:
				return false
	return true


func _shape_nodes_match_resources(
	shape_nodes: Array[CollisionShape2D],
	expected_shapes: Array[Shape2D]
) -> bool:
	if shape_nodes.size() != expected_shapes.size():
		return false
	for index in range(shape_nodes.size()):
		if shape_nodes[index].shape != expected_shapes[index]:
			return false
	return true


func _test_collision_shapes_mirror_with_facing(
	enemy_config: EnemyConfig,
	enemy: Enemy,
	animated_sprite: AnimatedSprite2D,
	body_shape_nodes: Array[CollisionShape2D],
	touch_shape_nodes: Array[CollisionShape2D]
) -> void:
	var all_shape_nodes: Array[CollisionShape2D] = []
	all_shape_nodes.append_array(body_shape_nodes)
	all_shape_nodes.append_array(touch_shape_nodes)
	var right_bounds: Array[Rect2] = []
	for shape_node in all_shape_nodes:
		right_bounds.append(_get_collision_shape_local_bounds(shape_node))

	enemy.call("_set_facing_left", true)
	_expect(
		animated_sprite.flip_h == (not enemy.sprite_faces_left_by_default),
		"%s facing left must use the configured sprite default direction." % enemy_config.resource_path
	)
	for index in range(all_shape_nodes.size()):
		var left_bound := _get_collision_shape_local_bounds(all_shape_nodes[index])
		_expect(
			_are_bounds_mirrored_on_x(right_bounds[index], left_bound),
			"%s collision shape %d must mirror when facing left." % [enemy_config.resource_path, index]
		)

	enemy.call("_set_facing_left", false)
	_expect(
		animated_sprite.flip_h == enemy.sprite_faces_left_by_default,
		"%s facing right must use the configured sprite default direction." % enemy_config.resource_path
	)
	for index in range(all_shape_nodes.size()):
		var restored_bound := _get_collision_shape_local_bounds(all_shape_nodes[index])
		_expect(
			_are_bounds_equal(right_bounds[index], restored_bound),
			"%s collision shape %d must restore when facing right." % [enemy_config.resource_path, index]
		)


func _get_collision_shape_local_bounds(shape_node: CollisionShape2D) -> Rect2:
	if shape_node == null or shape_node.shape == null:
		return Rect2()

	var shape_rect: Rect2 = shape_node.shape.get_rect()
	var corners: Array[Vector2] = [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	var minimum: Vector2 = Vector2(INF, INF)
	var maximum: Vector2 = Vector2(-INF, -INF)
	for corner in corners:
		var transformed_corner: Vector2 = shape_node.transform * corner
		minimum.x = minf(minimum.x, transformed_corner.x)
		minimum.y = minf(minimum.y, transformed_corner.y)
		maximum.x = maxf(maximum.x, transformed_corner.x)
		maximum.y = maxf(maximum.y, transformed_corner.y)
	return Rect2(minimum, maximum - minimum)


func _are_bounds_mirrored_on_x(right_bound: Rect2, left_bound: Rect2) -> bool:
	var right_min_x := right_bound.position.x
	var right_max_x := right_bound.position.x + right_bound.size.x
	var left_min_x := left_bound.position.x
	var left_max_x := left_bound.position.x + left_bound.size.x
	return (
		is_equal_approx(left_min_x, -right_max_x)
		and is_equal_approx(left_max_x, -right_min_x)
		and is_equal_approx(left_bound.position.y, right_bound.position.y)
		and is_equal_approx(left_bound.size.y, right_bound.size.y)
	)


func _are_bounds_equal(expected_bound: Rect2, actual_bound: Rect2) -> bool:
	return (
		is_equal_approx(actual_bound.position.x, expected_bound.position.x)
		and is_equal_approx(actual_bound.position.y, expected_bound.position.y)
		and is_equal_approx(actual_bound.size.x, expected_bound.size.x)
		and is_equal_approx(actual_bound.size.y, expected_bound.size.y)
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
