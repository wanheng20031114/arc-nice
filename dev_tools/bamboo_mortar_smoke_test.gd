extends SceneTree

# Match production bootstrap order before loading the standalone mortar graph;
# this keeps Enemy, runtime and registry global classes out of a preload cycle.
const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const MORTAR_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar.tscn"
)
const MORTAR_CONFIG := preload(
	"res://resources/config/plant_defense/bamboo_mortar.tres"
)
const SHELL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_HIT_EFFECT_SCENE := preload(
	"res://scene/enemy/enemy_hit_effect.tscn"
)
const LINGLAN_BOSS_SCENE := preload(
	"res://scene/boss/linglan/linglan_boss.tscn"
)
const SPLIT_LIFECYCLE_SHADER := preload(
	"res://resources/shader/bamboo_mortar_split_lifecycle.gdshader"
)
const SPLIT_LIFECYCLE_MATERIAL := preload(
	"res://resources/shader/bamboo_mortar_split_lifecycle_material.tres"
)
const SOFT_MICRO_LIGHT_TEXTURE := preload(
	"res://resources/lighting/soft_micro_point_light.tres"
)
const SOFT_WHITE_LIGHT_TEXTURE := preload(
	"res://resources/lighting/soft_white_point_light.tres"
)
const MORTAR_FIRE_AUDIO := preload(
	"res://resources/audio/capoo_rpg_launch.wav"
)
const MORTAR_EXPLOSION_AUDIO := preload(
	"res://resources/audio/cowboy_explosion.wav"
)
const EXPLOSION_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/explosion_audio_limiter.gd"
)
const ARMORED_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_shell.tres"
)
const PLAYER_SCENES: Array[PackedScene] = [
	preload("res://scene/player/hoe_cat/player_hoe_cat.tscn"),
	preload("res://scene/player/tiyi/player_tiyi.tscn"),
	preload(
		"res://scene/player/weishidaier/player_weishidaier.tscn"
	),
]

var failures: Array[String] = []
var runtime: MortarRuntimeStub = null
var enemies: Array[Enemy] = []


class MortarRuntimeStub:
	extends CombatRuntimeTestFixture

	var candidates: Array[Enemy] = []
	var query_count := 0
	var last_query_radius := 0.0
	var queued_visuals: Array[Dictionary] = []
	var damage_records: Array[Dictionary] = []
	var session_object_pool: SessionObjectPool = null
	var plant_gameplay_port: MortarPlantPort = null
	var apply_real_damage := false

	func install_pool() -> void:
		install_base_runtime_nodes()
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		session_object_pool.register_scene(SHELL_SCENE, 1, 8)
		plant_gameplay_port = MortarPlantPort.new()
		plant_gameplay_port.fixture_runtime = self
		plant_gameplay_port.name = "TowerPlantGameplayPort"
		add_child(plant_gameplay_port)

	func query_combat_targets_unordered_into(
		center: Vector2,
		radius: float,
		result: Array[Enemy]
	) -> void:
		query_count += 1
		last_query_radius = radius
		result.clear()
		var radius_squared := radius * radius
		for candidate in candidates:
			if (
				candidate != null
				and is_instance_valid(candidate)
				and not candidate.is_dead
				and center.distance_squared_to(candidate.global_position)
				<= radius_squared
			):
				result.append(candidate)

	func queue_bamboo_mortar_visual(
		plant_net_id: int,
		action_id: int,
		stage: int,
		spawn_position: Vector2,
		landing_position: Vector2,
		committed_windup_duration_seconds: float
	) -> void:
		queued_visuals.append({
			"plant_net_id": plant_net_id,
			"action_id": action_id,
			"stage": stage,
			"spawn_position": spawn_position,
			"landing_position": landing_position,
			"committed_windup_duration_seconds": committed_windup_duration_seconds,
		})

	func apply_authoritative_plant_enemy_damage(
		source_id: int,
		enemy: Enemy,
		damage: int,
		impact_direction: Vector2,
		damage_type: EnemyConfig.DamageType
	) -> bool:
		damage_records.append({
			"source_id": source_id,
			"enemy": enemy,
			"damage": damage,
			"impact_direction": impact_direction,
			"damage_type": damage_type,
		})
		if apply_real_damage:
			return enemy.apply_damage(
				damage,
				impact_direction,
				damage_type,
				false
			)
		return true

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return (
			session_object_pool != null
			and session_object_pool.is_registered(scene)
		)

	func acquire_session_object(
		scene: PackedScene,
		strict: bool = false
	) -> Node:
		if session_object_pool == null:
			return null
		var instance := (
			session_object_pool.try_acquire(scene)
			if strict
			else session_object_pool.acquire(scene)
		)
		var shell := instance as BambooMortarShell
		if shell != null:
			shell.bind_gameplay_context(self, plant_gameplay_port)
		return instance


class MortarPlantPort:
	extends TowerPlantGameplayPort

	var fixture_runtime: MortarRuntimeStub = null

	func broadcast_plant_projectile_visual(
		_plant_net_id: int,
		_spawn_position: Vector2,
		_direction: Vector2,
		_speed: float,
		_explosion_radius: float,
		_lifetime: float
	) -> bool:
		return false

	func queue_bamboo_mortar_visual(
		plant_net_id: int,
		action_id: int,
		stage: int,
		spawn_position: Vector2,
		landing_position: Vector2,
		committed_windup_duration_seconds: float
	) -> bool:
		if fixture_runtime == null:
			return false
		fixture_runtime.queue_bamboo_mortar_visual(
			plant_net_id,
			action_id,
			stage,
			spawn_position,
			landing_position,
			committed_windup_duration_seconds
		)
		return true

	func queue_hydrangea_rain_visual(
		_plant_net_id: int,
		_action_id: int,
		_target_position: Vector2,
		_action_elapsed_seconds: float
	) -> bool:
		return false

	func queue_corn_machine_gun_burst_visual(
		_plant_net_id: int,
		_action_id: int,
		_direction: Vector2
	) -> bool:
		return false

	func apply_authoritative_plant_enemy_damage(
		source_id: int,
		enemy_node: Node2D,
		damage: int,
		impact_direction: Vector2,
		damage_type: int
	) -> bool:
		if fixture_runtime == null:
			return false
		return fixture_runtime.apply_authoritative_plant_enemy_damage(
			source_id,
			enemy_node as Enemy,
			damage,
			impact_direction,
			damage_type
		)

	func apply_authoritative_plant_enemy_damage_batch(
		_source_id: int,
		enemy_node: Node2D,
		damage_amounts: PackedInt64Array,
		hit_counts: PackedInt32Array,
		impact_direction: Vector2,
		damage_type: int
	) -> bool:
		var enemy := enemy_node as Enemy
		return (
			enemy != null
			and enemy.apply_damage_batch(
				damage_amounts,
				hit_counts,
				impact_direction,
				damage_type
			)
		)

	func request_bamboo_mortar_target(
		_owner: Node2D,
		_minimum_range: float,
		_maximum_range: float,
		_callback: Callable
	) -> bool:
		return false

	func cancel_bamboo_mortar_target_request(_owner: Node) -> void:
		pass

	func queue_bamboo_mortar_explosion(
		landing_position: Vector2,
		inner_radius: float,
		outer_radius: float,
		inner_damage: int,
		outer_damage: int,
		damage_source_id: int
	) -> bool:
		if fixture_runtime == null:
			return false
		var targets: Array[Enemy] = []
		fixture_runtime.query_combat_targets_unordered_into(
			landing_position,
			outer_radius,
			targets
		)
		var inner_radius_squared := inner_radius * inner_radius
		var outer_radius_squared := outer_radius * outer_radius
		for enemy in targets:
			if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
				continue
			var distance_squared := landing_position.distance_squared_to(
				enemy.global_position
			)
			if distance_squared > outer_radius_squared:
				continue
			var applied_damage := (
				inner_damage
				if distance_squared <= inner_radius_squared
				else outer_damage
			)
			var impact_direction := landing_position.direction_to(
				enemy.global_position
			)
			if impact_direction == Vector2.ZERO:
				impact_direction = Vector2.UP
			apply_authoritative_plant_enemy_damage(
				damage_source_id,
				enemy,
				applied_damage,
				impact_direction,
				EnemyConfig.DamageType.PHYSICAL
			)
		return true

	func query_living_plants_in_radius_into(
		_center: Vector2,
		_radius: float,
		result: Array
	) -> void:
		result.clear()

	func begin_inventory_building_placement(
		_slot_index: int,
		_expected_inventory_revision: int
	) -> bool:
		return false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = MortarRuntimeStub.new()
	runtime.name = "BambooMortarSmokeFixture"
	runtime.install_pool()
	root.add_child(runtime)
	current_scene = runtime

	var authority := _create_mortar(false, 701)
	var proxy := _create_mortar(true, 702)
	if authority != null and proxy != null:
		_test_config_and_scene_contract(authority)
		_test_muzzle_night_light_curve(authority)
		_test_semantic_layers_and_z_order(authority)
		await _test_split_lifecycle_transition_contract()
		await _test_target_ring_and_tracking(authority)
		await _test_windup_fire_and_fixed_landing(authority)
		await _test_shell_duration_and_late_join(authority)
		await _test_explosion_damage_boundaries()
		await _test_physical_defense_settlement()
		await _test_proxy_actions_and_runtime_state(authority, proxy)
		await _test_pool_reuse()

	await _cleanup()
	if failures.is_empty():
		print("BAMBOO_MORTAR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _create_mortar(as_proxy: bool, net_id: int) -> BambooMortar:
	var mortar := MORTAR_SCENE.instantiate() as BambooMortar
	_expect(mortar != null, "竹筒迫击炮场景必须实例化为 BambooMortar。")
	if mortar == null:
		return null
	mortar.set_meta(&"net_id", net_id)
	mortar.bind_gameplay_context(runtime, runtime.plant_gameplay_port)
	runtime.add_child(mortar)
	mortar.setup(MORTAR_CONFIG, null, [], as_proxy)
	mortar.attack_timer.stop()
	mortar.target_track_timer.stop()
	return mortar


func _test_config_and_scene_contract(mortar: BambooMortar) -> void:
	var status_glow_texture := (
		SOFT_MICRO_LIGHT_TEXTURE as GradientTexture2D
	)
	var fire_audio := (
		mortar.get_node_or_null("FireAudio") as AudioStreamPlayer2D
	)
	_expect(
		TOWER_SCENE != null and MORTAR_CONFIG.is_valid(),
		"塔防场景与竹筒迫击炮配置必须有效。"
	)
	_expect(
		MORTAR_CONFIG.plant_id == &"bamboo_mortar"
		and MORTAR_CONFIG.display_name == "竹筒迫击炮"
		and MORTAR_CONFIG.max_health == 2000
		and MORTAR_CONFIG.physical_defense == 20
		and MORTAR_CONFIG.magic_defense == 20
		and MORTAR_CONFIG.attack_damage == 140
		and is_zero_approx(MORTAR_CONFIG.get_attack_interval())
		and is_equal_approx(MORTAR_CONFIG.attack_range, 224.0)
		and MORTAR_CONFIG.description.contains("4至14格")
		and MORTAR_CONFIG.description.contains("140点")
		and MORTAR_CONFIG.description.contains("70点")
		and mortar.configured_attack_damage == 140
		and is_equal_approx(mortar.configured_attack_range, 224.0)
		and BambooMortar.DEFAULT_ATTACK_DAMAGE == 140
		and BambooMortar.OUTER_ATTACK_DAMAGE == 70
		and is_equal_approx(BambooMortar.DEFAULT_ATTACK_RANGE, 224.0)
		and BambooMortarShell.DEFAULT_INNER_DAMAGE == 140
		and BambooMortarShell.DEFAULT_OUTER_DAMAGE == 70
		and MORTAR_CONFIG.footprint_size == Vector2i(2, 2)
		and MORTAR_CONFIG.placement_surface
		== PlantDefenseConfig.PlacementSurface.GRASS_ONLY
		and MORTAR_CONFIG.supports_multiplayer,
		"迫击炮数值必须为2000生命、20物防、20法防、140/70伤害、无额外攻击间隔、224范围、草地2×2且支持多人。"
	)
	_expect(
		PlantDefenseRegistry.get_config(&"bamboo_mortar")
		== MORTAR_CONFIG
		and PlantDefenseRegistry.get_all_configs().size() == 18
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"excavator")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"stone_mill")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"simple_fence")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"life_tower")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"speed_tower")
		)
		and PlantDefenseRegistry.get_all_configs().has(MORTAR_CONFIG),
		"迫击炮必须按防御塔语义注册，并与其余17种建筑共同进入公共注册表。"
	)
	_expect(
		mortar.main_sprite.sprite_frames.get_frame_count(&"charge") == 8
		and is_equal_approx(
			mortar.main_sprite.sprite_frames.get_animation_speed(&"charge"),
			2.0
		)
		and not mortar.main_sprite.sprite_frames.get_animation_loop(&"charge"),
		"蓄热必须是8帧、2 FPS、非循环动画，总时长4秒。"
	)
	_expect(
		mortar.main_sprite.sprite_frames.get_frame_count(&"fire") == 4
		and is_equal_approx(
			mortar.main_sprite.sprite_frames.get_animation_speed(&"fire"),
			12.0
		)
		and not mortar.main_sprite.sprite_frames.get_animation_loop(&"fire"),
		"蓄热后必须播放4帧、12 FPS、非循环的明确出膛动画。"
	)
	_expect(
		mortar.get_node_or_null("TargetingArea") == null
		and mortar.get_node_or_null("VisualRoot/Muzzle") is Marker2D
		and mortar.get_node_or_null(
			"VisualRoot/Muzzle/MuzzleGlow"
		) is NightPointLight2D
		and mortar.get_node_or_null("VisualRoot/StatusLight") is Polygon2D
		and mortar.get_node_or_null(
			"VisualRoot/StatusLight/MicroGlow"
		) is NightPointLight2D
		and mortar.get_node_or_null("VisualRoot/LowerBody") is Sprite2D
		and mortar.get_node_or_null("VisualRoot/GlowSprite") == null
		and mortar.get_node_or_null("AttackTimer") is Timer
		and mortar.get_node_or_null("TargetTrackTimer") is Timer
		and fire_audio != null
		and fire_audio.stream == MORTAR_FIRE_AUDIO
		and fire_audio.bus == &"SFX"
		and is_equal_approx(fire_audio.volume_db, -10.0)
		and is_equal_approx(fire_audio.max_distance, 300.0)
		and fire_audio.max_polyphony == 2,
		"迫击炮必须用预建炮口Marker及炮口夜灯、独立方形状态灯及其原生微光、Timer与音效节点，且不能常驻TargetingArea。"
	)
	_expect(
		mortar.status_glow_light.texture == SOFT_MICRO_LIGHT_TEXTURE
		and status_glow_texture != null
		and status_glow_texture.fill
		== GradientTexture2D.FILL_RADIAL
		and status_glow_texture.fill_from == Vector2(0.5, 0.5)
		and status_glow_texture.fill_to == Vector2(1.0, 0.5)
		and status_glow_texture.gradient.sample(0.0).r > 0.95
		and status_glow_texture.gradient.sample(1.0).r < 0.01
		and is_equal_approx(
			mortar.status_glow_light.texture_scale,
			1.35
		)
		and mortar.status_glow_light.texture_filter
		== CanvasItem.TEXTURE_FILTER_LINEAR
		and mortar.status_glow_light.blend_mode
		== Light2D.BLEND_MODE_ADD
		and not mortar.status_glow_light.shadow_enabled
		and mortar.status_glow_light.get_parent() == mortar.status_light,
		"攻击状态方格必须拥有随可见性继承、线性采样且径向衰减的小半径PointLight2D微光。"
	)
	var muzzle_light_texture := (
		mortar.muzzle_glow_light.texture as GradientTexture2D
	)
	_expect(
		mortar.muzzle_glow_light.get_parent() == mortar.muzzle
		and mortar.muzzle_glow_light.position == Vector2.ZERO
		and is_equal_approx(
			absf(mortar.muzzle_glow_light.global_scale.x),
			absf(mortar.muzzle_glow_light.global_scale.y)
		)
		and mortar.muzzle_glow_light.texture == SOFT_WHITE_LIGHT_TEXTURE
		and muzzle_light_texture != null
		and muzzle_light_texture.width == 256
		and muzzle_light_texture.height == 256
		and muzzle_light_texture.fill
		== GradientTexture2D.FILL_RADIAL
		and is_equal_approx(
			mortar.muzzle_glow_light.texture_scale,
			BambooMortar.MUZZLE_CHARGE_TEXTURE_SCALE_MIN
		)
		and is_zero_approx(mortar.muzzle_glow_light.night_energy)
		and not mortar.muzzle_glow_light.starts_emitting
		and not mortar.muzzle_glow_light.enabled
		and not mortar.muzzle_glow_light.shadow_enabled
		and mortar.muzzle_glow_light.texture_filter
		== CanvasItem.TEXTURE_FILTER_LINEAR
		and mortar.muzzle_glow_light.blend_mode
		== Light2D.BLEND_MODE_ADD
		and not mortar.muzzle_glow_light.is_processing()
		and not mortar.muzzle_glow_light.is_physics_processing(),
		"炮口必须预建默认关闭、无阴影且无逐帧回调的柔和径向夜灯，并严格跟随规范Muzzle锚点。"
	)
	_expect(
		mortar.attack_timer.one_shot
		and is_equal_approx(mortar.attack_timer.wait_time, 2.0)
		and is_equal_approx(
			mortar.target_track_timer.wait_time,
			0.5
		),
		"场景计时器必须仅保留2秒无目标重试和0.5秒目标位置采样。"
	)
	_expect(
		mortar.get_node("VisualRoot").scale == Vector2(0.5, 0.5)
		and mortar.main_sprite.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and mortar.status_light.polygon
		== PackedVector2Array([
			Vector2(-8, -8),
			Vector2(8, -8),
			Vector2(8, 8),
			Vector2(-8, 8),
		])
		and mortar.status_light.uv
		== PackedVector2Array([
			Vector2(0, 0),
			Vector2(1, 0),
			Vector2(1, 1),
			Vector2(0, 1),
		]),
		"64×64主体必须以0.5缩放和邻近过滤显示，状态灯必须以单个16×16逻辑像素节点承载清晰6×6核心。"
	)
	var mortar_source := FileAccess.get_file_as_string(
		"res://scene/plant_defense/bamboo_mortar.gd"
	)
	var shell_source := FileAccess.get_file_as_string(
		"res://scene/plant_defense/bamboo_mortar_shell.gd"
	)
	var glow_shader_source := FileAccess.get_file_as_string(
		"res://resources/shader/bamboo_mortar_glow.gdshader"
	)
	_expect(
		not mortar_source.contains("func _process(")
		and not mortar_source.contains("PhysicsRayQueryParameters2D")
		and mortar_source.contains(
			"query_combat_targets_unordered_into"
		)
		and shell_source.contains(
			"query_combat_targets_unordered_into"
		)
		and not shell_source.contains("intersect_shape"),
		"迫击炮不得常驻逐帧脚本、视线射线或物理分页爆炸查询，索敌与爆炸必须复用共享索引。"
	)
	_expect(
		bool(
			ProjectSettings.get_setting(
				"rendering/viewport/hdr_2d",
				false
			)
		)
		and glow_shader_source.count("\ninstance uniform ") == 0
		and glow_shader_source.contains("vec3 active_color = COLOR.rgb")
		and glow_shader_source.contains("blend_mix")
		and glow_shader_source.contains("varying vec2 shape_uv")
		and glow_shader_source.contains(
			"shape_uv = (VERTEX + vec2(8.0)) / 16.0"
		)
		and not glow_shader_source.contains(
			"abs(UV - vec2(0.5))"
		)
		and glow_shader_source.contains("core_mask")
		and not glow_shader_source.contains("core_border_mask")
		and not glow_shader_source.contains("inner_halo_mask")
		and not glow_shader_source.contains("outer_halo_mask")
		and not glow_shader_source.contains("pulse")
		and glow_shader_source.contains(
			"COLOR = vec4(active_color, COLOR.a) * core_mask"
		)
		and not FileAccess.file_exists(
			"res://resources/texture/plant_defense/bamboo_mortar/glow_mask.png"
		),
		"中下部状态灯shader只能绘制对应颜色的实心亮核，外围渐变必须交给PointLight2D，不能残留离散方环或贴图灯遮罩。"
	)
	mortar.call("_set_glow_state", true, 7)
	mortar.status_glow_light.set_night_factor(1.0)
	_expect(
		mortar.status_light.color.is_equal_approx(
			Color(3.4875, 0.961, 0.155, 1.0)
		)
		and mortar.status_glow_light.color.is_equal_approx(
			BambooMortar.CHARGE_LIGHT_COLOR
		)
		and is_equal_approx(
			mortar.status_glow_light.night_energy,
			BambooMortar.CHARGE_LIGHT_ENERGY_MAX
		)
		and mortar.status_glow_light.enabled
		and is_equal_approx(
			mortar.status_glow_light.energy,
			BambooMortar.CHARGE_LIGHT_ENERGY_MAX
		),
		"满蓄热状态灯必须保留1.55倍橙色亮核，并同步增强小范围橙色外溢光。"
	)
	mortar.call("_set_glow_state", false, 0)
	_expect(
		mortar.status_light.color.is_equal_approx(
			Color(0.34, 1.65, 0.18, 1.0)
		)
		and mortar.status_glow_light.color.is_equal_approx(
			BambooMortar.IDLE_LIGHT_COLOR
		)
		and is_equal_approx(
			mortar.status_glow_light.night_energy,
			BambooMortar.IDLE_LIGHT_ENERGY
		)
		and mortar.status_glow_light.enabled
		and is_equal_approx(
			mortar.status_glow_light.energy,
			BambooMortar.IDLE_LIGHT_ENERGY
		),
		"待机状态灯必须恢复嫩绿色亮核与更克制的小范围外溢光。"
	)
	mortar.status_glow_light.set_night_factor(0.0)
	_expect(
		not mortar.status_glow_light.enabled
		and is_zero_approx(mortar.status_glow_light.energy),
		"白天必须关闭状态格PointLight2D，只保留中心方格本身。"
	)


func _test_muzzle_night_light_curve(mortar: BambooMortar) -> void:
	var light := mortar.muzzle_glow_light
	var light_instance_id := light.get_instance_id()
	var muzzle_child_count := mortar.muzzle.get_child_count()
	light.set_night_factor(1.0)

	mortar.call(
		"_apply_muzzle_light_state",
		BambooMortar.MuzzleLightPhase.CHARGE,
		0
	)
	var charge_start_energy := light.night_energy
	var charge_start_scale := light.texture_scale
	mortar.call(
		"_apply_muzzle_light_state",
		BambooMortar.MuzzleLightPhase.CHARGE,
		3
	)
	var charge_mid_energy := light.night_energy
	var charge_mid_scale := light.texture_scale
	mortar.call(
		"_apply_muzzle_light_state",
		BambooMortar.MuzzleLightPhase.CHARGE,
		BambooMortar.WINDUP_FRAME_COUNT - 1
	)
	var charge_end_energy := light.night_energy
	var charge_end_scale := light.texture_scale
	var inherited_scale := absf(light.global_scale.x)
	var charge_start_radius := (
		float(light.texture.get_width())
		* charge_start_scale
		* inherited_scale
		* 0.5
	)
	var charge_end_radius := (
		float(light.texture.get_width())
		* charge_end_scale
		* inherited_scale
		* 0.5
	)
	_expect(
		light.color.is_equal_approx(
			BambooMortar.MUZZLE_CHARGE_LIGHT_COLOR
		)
		and light.is_emission_allowed()
		and light.enabled
		and is_equal_approx(
			charge_start_energy,
			BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MIN
		)
		and charge_start_energy < charge_mid_energy
		and charge_mid_energy < charge_end_energy
		and is_equal_approx(
			charge_end_energy,
			BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MAX
		)
		and is_equal_approx(
			charge_start_scale,
			BambooMortar.MUZZLE_CHARGE_TEXTURE_SCALE_MIN
		)
		and charge_start_scale < charge_mid_scale
		and charge_mid_scale < charge_end_scale
		and is_equal_approx(
			charge_end_scale,
			BambooMortar.MUZZLE_CHARGE_TEXTURE_SCALE_MAX
		)
		and absf(charge_start_radius - 12.8) <= 0.01
		and absf(charge_end_radius - 32.0) <= 0.01,
		"夜间炮口预热光必须按现有8帧事件平滑增强，并把实际半径从约13像素扩散到32像素。"
	)

	light.set_night_factor(0.0)

	_expect(
		not light.enabled
		and is_zero_approx(light.energy)
		and is_equal_approx(
			light.night_energy,
			BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MAX
		),
		"同一预热状态切到白天时必须关闭真实炮口灯，但保留可在夜幕恢复的阶段强度。"
	)
	light.set_night_factor(1.0)

	var fire_energies: Array[float] = []
	var fire_scales: Array[float] = []
	for frame_index in range(BambooMortar.FIRE_FRAME_COUNT):
		mortar.call(
			"_apply_muzzle_light_state",
			BambooMortar.MuzzleLightPhase.FIRE,
			frame_index
		)
		fire_energies.append(light.night_energy)
		fire_scales.append(light.texture_scale)
	var launch_radius := (
		float(light.texture.get_width())
		* fire_scales[BambooMortar.FIRE_LAUNCH_FRAME]
		* inherited_scale
		* 0.5
	)
	_expect(
		light.color.is_equal_approx(BambooMortar.MUZZLE_FIRE_LIGHT_COLOR)
		and fire_energies[0] > charge_end_energy
		and fire_energies[1] > fire_energies[0]
		and fire_energies[1] > fire_energies[2]
		and fire_energies[2] > fire_energies[3]
		and is_equal_approx(
			fire_energies[BambooMortar.FIRE_LAUNCH_FRAME],
			float(BambooMortar.MUZZLE_FIRE_LIGHT_ENERGIES[
				BambooMortar.FIRE_LAUNCH_FRAME
			])
		)
		and fire_scales[1] > fire_scales[0]
		and fire_scales[1] > fire_scales[2]
		and fire_scales[2] > fire_scales[3]
		and absf(launch_radius - 46.08) <= 0.01,
		"出膛光必须在fire_1规范发射帧达到1.55峰值与约46像素半径，随后两帧快速收束。"
	)

	mortar.call(
		"_apply_muzzle_light_state",
		BambooMortar.MuzzleLightPhase.OFF,
		0
	)
	_expect(
		light.get_instance_id() == light_instance_id
		and mortar.muzzle.get_child_count() == muzzle_child_count
		and not light.is_emission_allowed()
		and not light.enabled
		and is_zero_approx(light.energy)
		and is_zero_approx(light.night_energy)
		and is_equal_approx(
			light.texture_scale,
			BambooMortar.MUZZLE_CHARGE_TEXTURE_SCALE_MIN
		)
		and not light.is_processing()
		and not light.is_physics_processing(),
		"炮口光结束后必须复用同一预建节点并立即完全归零，禁止动态节点、常驻Tween或逐帧处理。"
	)
	light.set_night_factor(0.0)


func _test_semantic_layers_and_z_order(mortar: BambooMortar) -> void:
	var visual_root := mortar.get_node("VisualRoot") as Node2D
	var animated_sprite_count := _count_animated_sprites(mortar)
	var shell_source := FileAccess.get_file_as_string(
		"res://scene/plant_defense/bamboo_mortar_shell.gd"
	)
	_expect(
		animated_sprite_count == 1
		and mortar.lower_body.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and mortar.lower_body.material == SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == SPLIT_LIFECYCLE_MATERIAL
		and mortar.lifecycle_visual_paths.is_empty()
		and SPLIT_LIFECYCLE_MATERIAL.shader
		== SPLIT_LIFECYCLE_SHADER,
		"分层迫击炮必须只保留一个动画播放器；上下互补层须共享迫击炮专用的压缩生命周期材质。"
	)
	var split_shader_source := SPLIT_LIFECYCLE_SHADER.code
	_expect(
		split_shader_source.count("\ninstance uniform ") == 0
		and split_shader_source.contains(
			"uniform vec4 lifecycle_state"
		)
		and split_shader_source.contains(
			"uniform vec2 damage_status_strength"
		)
		and split_shader_source.contains("burn_overlay_color")
		and split_shader_source.contains("bleed_overlay_color")
		and not split_shader_source.contains("slow_overlay_strength")
		and split_shader_source.contains(
			"noise_x_index / NOISE_X_DENOMINATOR"
		)
		and split_shader_source.contains(
			"lifecycle_world_position / 64.0"
		)
		and split_shader_source.contains(
			"lifecycle_origin_world_y + EFFECT_TOP_LOCAL_Y"
		),
		"上下层必须完全避开实例参数，并从一个过渡材质状态中无损解码同一世界坐标溶解噪波，避免Compatibility渲染器为每个CanvasItem固定预留16项。"
	)
	_expect(
		visual_root.z_index == 0
		and mortar.lower_body.z_index == 0
		and mortar.status_light.z_index == 0
		and mortar.main_sprite.z_index == 4,
		"迫击炮必须使用下层0、状态灯0、上炮管4的显式局部层级，使炮管严格高于敌我身体且不抬高到战斗特效层之上。"
	)

	var base_enemy := ENEMY_SCENE.instantiate() as Enemy
	var enemy_sprite := (
		base_enemy.get_node_or_null("AnimatedSprite2D")
		as AnimatedSprite2D
		if base_enemy != null
		else null
	)
	_expect(
		enemy_sprite != null
		and _effective_z_index(enemy_sprite) == 2,
		"基础敌人身体必须显式位于玩家之上的有效z=2。"
	)
	if base_enemy != null:
		base_enemy.free()

	var boss := LINGLAN_BOSS_SCENE.instantiate() as Enemy
	var boss_sprite := (
		boss.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if boss != null
		else null
	)
	_expect(
		boss_sprite != null
		and _effective_z_index(boss_sprite) == 3
		and _effective_z_index(boss_sprite)
		< _effective_z_index(mortar.main_sprite),
		"Boss身体必须保持有效z=3，位于上炮管z=4之下并继续低于既有z=4弹体。"
	)
	if boss != null:
		boss.free()

	var shell := SHELL_SCENE.instantiate() as BambooMortarShell
	var enemy_hit_effect := (
		ENEMY_HIT_EFFECT_SCENE.instantiate() as GPUParticles2D
	)
	var impact_audio := (
		shell.get_node_or_null("ImpactAudio") as AudioStreamPlayer2D
		if shell != null
		else null
	)
	_expect(
		shell != null
		and enemy_hit_effect != null
		and shell.z_index == 4
		and enemy_hit_effect.z_index == 4
		and shell.z_index == mortar.main_sprite.z_index
		and enemy_hit_effect.z_index == mortar.main_sprite.z_index,
		"迫击炮上管、既有迫击炮弹与敌人命中特效必须同处z=4，均高于有效z=3的Boss身体且不越过z=5以上战斗特效。"
	)
	_expect(
		impact_audio != null
		and impact_audio.stream == MORTAR_EXPLOSION_AUDIO
		and impact_audio.bus == &"SFX"
		and is_equal_approx(impact_audio.volume_db, -9.0)
		and is_equal_approx(impact_audio.max_distance, 300.0)
		and impact_audio.max_polyphony == 1
		and shell_source.contains(
			"EXPLOSION_AUDIO_LIMITER.play(impact_audio)"
		)
		and shell_source.count(
			"EXPLOSION_AUDIO_LIMITER.stop(impact_audio)"
		) == 3
		and shell_source.contains(
			"VOICE_PREEMPTED_CALLBACK_META"
		)
		and shell_source.contains(
			"func _try_finish_explosion()"
		),
		"炮弹爆炸必须复用原石虫爆炸音效，并通过共享爆炸限流器播放及释放池化语音。"
	)
	if shell != null:
		shell.free()
	if enemy_hit_effect != null:
		enemy_hit_effect.free()

	for player_scene in PLAYER_SCENES:
		var player := player_scene.instantiate()
		var body_sprite := (
			player.get_node_or_null("BodySprite") as AnimatedSprite2D
			if player != null
			else null
		)
		_expect(
			body_sprite != null
			and _effective_z_index(mortar.lower_body)
			< _effective_z_index(body_sprite)
			and _effective_z_index(body_sprite) == 1
			and _effective_z_index(body_sprite)
			< _effective_z_index(mortar.main_sprite),
			"三名玩家身体必须稳定夹在迫击炮下层z=0与上炮管z=4之间。"
		)
		if player != null:
			player.free()

	var original_noise_offset: Vector2 = mortar.call(
		"_make_lifecycle_noise_offset"
	)
	var lifecycle_probe_noise := Vector2(
		125.0 / 997.0,
		619.0 / 991.0
	)
	mortar.call("_activate_transition_lifecycle_material")
	mortar.call(
		"_set_lifecycle_parameter",
		&"construction_progress",
		0.35
	)
	mortar.call(
		"_set_lifecycle_parameter",
		&"construction_front_strength",
		0.6
	)
	mortar.call("_set_lifecycle_parameter", &"removal_enabled", true)
	mortar.call("_set_lifecycle_parameter", &"removal_progress", 0.4)
	mortar.call(
		"_set_lifecycle_parameter",
		&"noise_offset",
		lifecycle_probe_noise
	)
	var transition_material := (
		mortar.lower_body.material as ShaderMaterial
	)
	var lower_lifecycle_state: Vector4 = (
		transition_material.get_shader_parameter(
			&"lifecycle_state"
		)
	)
	_expect(
		transition_material != SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == transition_material
		and is_equal_approx(lower_lifecycle_state.x, 0.35)
		and is_equal_approx(lower_lifecycle_state.y, 0.6)
		and is_equal_approx(lower_lifecycle_state.z, 0.4)
		and is_equal_approx(
			lower_lifecycle_state.w,
			float(125 * 1024 + 619)
		),
		"基类生命周期变化必须只更新上下层共享的临时普通材质，并精确保留两维噪波索引。"
	)
	mortar.call(
		"_set_lifecycle_parameter",
		&"construction_progress",
		1.0
	)
	mortar.call(
		"_set_lifecycle_parameter",
		&"construction_front_strength",
		0.0
	)
	mortar.call("_set_lifecycle_parameter", &"removal_enabled", false)
	mortar.call("_set_lifecycle_parameter", &"removal_progress", 0.0)
	mortar.call(
		"_set_lifecycle_parameter",
		&"noise_offset",
		original_noise_offset
	)
	mortar.call("_release_transition_lifecycle_material")
	_expect(
		mortar.lower_body.material == SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == SPLIT_LIFECYCLE_MATERIAL
		and (
			SPLIT_LIFECYCLE_MATERIAL.get_shader_parameter(
				&"lifecycle_state"
			) as Vector4
		).is_equal_approx(Vector4(1.0, 0.0, -1.0, 0.0)),
		"生命周期结束后上下层必须恢复只读共享材质，且不得污染其默认状态。"
	)

	_expect(
		mortar.set_damage_status_visual_active(&"burn", true),
		"竹筒迫击炮必须接受燃烧主体着色。"
	)
	var burn_status_material := mortar.lower_body.material as ShaderMaterial
	var burn_status_strength := (
		burn_status_material.get_shader_parameter(
			&"damage_status_strength"
		) as Vector2
	)
	mortar.call("_release_transition_lifecycle_material")
	_expect(
		burn_status_material != SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == burn_status_material
		and is_equal_approx(
			burn_status_strength.x,
			PlantDefense.BURN_OVERLAY_ACTIVE_STRENGTH
		),
		"迫击炮燃烧期间必须保留实例独立材质，构建结束释放路径不得清掉状态。"
	)
	mortar.set_damage_status_visual_active(&"bleed", true)
	mortar.set_damage_status_visual_active(&"burn", false)
	var bleed_status_strength := (
		burn_status_material.get_shader_parameter(
			&"damage_status_strength"
		) as Vector2
	)
	_expect(
		is_zero_approx(bleed_status_strength.x)
		and is_equal_approx(
			bleed_status_strength.y,
			PlantDefense.BLEED_OVERLAY_ACTIVE_STRENGTH
		)
		and not mortar.set_damage_status_visual_active(&"cold", true),
		"迫击炮必须可从燃烧切换到流血着色，同时拒绝寒冷移动视觉。"
	)
	mortar.set_damage_status_visual_active(&"bleed", false)
	_expect(
		mortar.lower_body.material == SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == SPLIT_LIFECYCLE_MATERIAL
		and (
			SPLIT_LIFECYCLE_MATERIAL.get_shader_parameter(
				&"damage_status_strength"
			) as Vector2
		).is_zero_approx(),
		"迫击炮伤害状态结束后必须恢复共享零状态材质，不得污染其他实例。"
	)

	var source_names := PackedStringArray([
		"idle",
		"charge_0",
		"charge_1",
		"charge_2",
		"charge_3",
		"charge_4",
		"charge_5",
		"charge_6",
		"charge_7",
		"fire_0",
		"fire_1",
		"fire_2",
		"fire_3",
	])
	for source_index in range(source_names.size()):
		var source_name := source_names[source_index]
		var animation_name := (
			&"idle"
			if source_index == 0
			else (&"charge" if source_index <= 8 else &"fire")
		)
		var frame_index := (
			0
			if source_index == 0
			else (
				source_index - 1
				if source_index <= 8
				else source_index - 9
			)
		)
		var full_texture := load(
			"res://resources/texture/plant_defense/bamboo_mortar/"
			+ source_name
			+ ".png"
		) as Texture2D
		var upper_texture := (
			mortar.main_sprite.sprite_frames.get_frame_texture(
				animation_name,
				frame_index
			)
		)
		var lower_texture := (
			BambooMortar.LOWER_IDLE_TEXTURE
			if source_index == 0
			else BambooMortar.LOWER_ACTIVE_TEXTURE
		)
		_expect(
			full_texture != null
			and upper_texture != null
			and _layers_losslessly_recompose(
				full_texture,
				upper_texture,
				lower_texture
			),
			"迫击炮%s帧必须由互不重叠的上炮管与下部图层逐像素无损重组。"
			% source_name
		)

	mortar.main_sprite.play(&"charge")
	_expect(
		mortar.lower_body.texture
		== BambooMortar.LOWER_ACTIVE_TEXTURE,
		"进入蓄热时静态下层必须切到空置侧管版本。"
	)
	mortar.main_sprite.play(&"fire")
	_expect(
		mortar.lower_body.texture
		== BambooMortar.LOWER_ACTIVE_TEXTURE,
		"进入开火时必须继续复用同一张静态活动下层。"
	)
	mortar.main_sprite.play(&"idle")
	_expect(
		mortar.lower_body.texture
		== BambooMortar.LOWER_IDLE_TEXTURE,
		"回到待机时静态下层必须恢复装填版本。"
	)


func _layers_losslessly_recompose(
	full_texture: Texture2D,
	upper_texture: Texture2D,
	lower_texture: Texture2D
) -> bool:
	var full_image := full_texture.get_image()
	var upper_image := upper_texture.get_image()
	var lower_image := lower_texture.get_image()
	if (
		full_image == null
		or upper_image == null
		or lower_image == null
		or full_image.get_size() != Vector2i(64, 64)
		or upper_image.get_size() != full_image.get_size()
		or lower_image.get_size() != full_image.get_size()
	):
		return false
	for y in range(64):
		for x in range(64):
			var full_pixel := full_image.get_pixel(x, y)
			var upper_pixel := upper_image.get_pixel(x, y)
			var lower_pixel := lower_image.get_pixel(x, y)
			if upper_pixel.a > 0.5 and lower_pixel.a > 0.5:
				return false
			if full_pixel.a <= 0.5:
				if upper_pixel.a > 0.5 or lower_pixel.a > 0.5:
					return false
				continue
			var recomposed_pixel := (
				upper_pixel
				if upper_pixel.a > 0.5
				else lower_pixel
			)
			if not recomposed_pixel.is_equal_approx(full_pixel):
				return false
	return true


func _effective_z_index(item: CanvasItem) -> int:
	var effective_z := 0
	var current: CanvasItem = item
	while current != null:
		effective_z += current.z_index
		if not current.z_as_relative:
			break
		current = current.get_parent() as CanvasItem
	return effective_z


func _count_animated_sprites(node: Node) -> int:
	var count := 1 if node is AnimatedSprite2D else 0
	for child in node.get_children():
		count += _count_animated_sprites(child)
	return count


func _test_split_lifecycle_transition_contract() -> void:
	var mortar := MORTAR_SCENE.instantiate() as BambooMortar
	_expect(
		mortar != null,
		"生命周期夹具必须实例化竹迫击炮。"
	)
	if mortar == null:
		return
	mortar.set_meta(&"net_id", 703)
	runtime.add_child(mortar)
	mortar.setup(
		MORTAR_CONFIG,
		null,
		[],
		true,
		-1,
		0,
		-1,
		true
	)
	mortar.attack_timer.stop()
	mortar.target_track_timer.stop()
	mortar.muzzle_glow_light.set_night_factor(1.0)
	var build_material := mortar.lower_body.material as ShaderMaterial
	var build_state: Vector4 = build_material.get_shader_parameter(
		&"lifecycle_state"
	)
	_expect(
		not mortar.is_operational
		and mortar.is_construction_visual_active()
		and not mortar.status_light.visible
		and not mortar.muzzle_glow_light.enabled
		and is_zero_approx(mortar.muzzle_glow_light.energy)
		and build_material != SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == build_material
		and is_zero_approx(build_state.x)
		and is_equal_approx(build_state.y, 1.0)
		and build_state.z < 0.0,
		"0.7秒构建期间上下层必须共享一份独立普通材质，且状态灯保持隐藏。"
	)
	await create_timer(0.75).timeout
	await process_frame
	_expect(
		mortar.is_operational
		and not mortar.is_construction_visual_active()
		and mortar.status_light.visible
		and not mortar.muzzle_glow_light.enabled
		and mortar.lower_body.material == SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == SPLIT_LIFECYCLE_MATERIAL,
		"构建完成后必须释放临时材质并恢复上下层共享运行态材质。"
	)

	mortar.call(
		"_apply_muzzle_light_state",
		BambooMortar.MuzzleLightPhase.CHARGE,
		BambooMortar.WINDUP_FRAME_COUNT - 1
	)
	_expect(
		mortar.muzzle_glow_light.enabled,
		"移除夹具必须先建立一盏真实活跃炮口灯，防止关闭断言伪通过。"
	)
	mortar.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	var removal_material := mortar.lower_body.material as ShaderMaterial
	var removal_state: Vector4 = removal_material.get_shader_parameter(
		&"lifecycle_state"
	)
	_expect(
		mortar.is_removing
		and not mortar.status_light.visible
		and not mortar.muzzle_glow_light.enabled
		and is_zero_approx(mortar.muzzle_glow_light.energy)
		and is_zero_approx(mortar.muzzle_glow_light.night_energy)
		and removal_material != SPLIT_LIFECYCLE_MATERIAL
		and mortar.main_sprite.material == removal_material
		and is_zero_approx(removal_state.z),
		"动画移除必须重新租用一份上下层共享普通材质，并从零进度同步溶解。"
	)
	await create_timer(0.75).timeout
	await process_frame
	_expect(
		not is_instance_valid(mortar),
		"竹迫击炮动画移除结束后必须正常释放节点。"
	)


func _test_target_ring_and_tracking(mortar: BambooMortar) -> void:
	await _clear_enemies()
	var too_close := _spawn_enemy(Vector2(64.0, 0.0))
	var nearest_valid := _spawn_enemy(Vector2(64.25, 0.0))
	var farther_valid := _spawn_enemy(Vector2(120.0, 0.0))
	var outer_edge := _spawn_enemy(Vector2(224.0, 0.0))
	var outside := _spawn_enemy(Vector2(224.25, 0.0))
	runtime.candidates.assign(enemies)
	var selected := mortar.call(
		"_select_nearest_target_in_ring"
	) as Enemy
	_expect(
		selected == nearest_valid,
		"索敌必须排除64像素边界并选择(64,224]内最近敌人。"
	)
	nearest_valid.is_dead = true
	selected = mortar.call("_select_nearest_target_in_ring") as Enemy
	_expect(
		selected == farther_valid,
		"最近目标失效后必须在同一无序候选缓冲中选择下一名目标。"
	)
	farther_valid.global_position = Vector2(100.0, 0.0)
	mortar.pending_target = farther_valid
	mortar.last_valid_target_position = Vector2(80.0, 0.0)
	mortar.call("_update_last_valid_target_position")
	_expect(
		mortar.last_valid_target_position == Vector2(100.0, 0.0),
		"有效目标的位置必须按0.5秒采样更新。"
	)
	farther_valid.global_position = Vector2(225.0, 0.0)
	mortar.call("_update_last_valid_target_position")
	farther_valid.is_dead = true
	mortar.call("_update_last_valid_target_position")
	_expect(
		mortar.last_valid_target_position == Vector2(100.0, 0.0),
		"目标离开范围或死亡后必须保留最后一次有效落点。"
	)
	var freed_during_windup := _spawn_enemy(Vector2(112.0, 0.0))
	mortar.pending_target = freed_during_windup
	var preserved_position := mortar.last_valid_target_position
	freed_during_windup.queue_free()
	await process_frame
	mortar.call("_update_last_valid_target_position")
	_expect(
		mortar.pending_target == null
		and mortar.last_valid_target_position == preserved_position,
		"目标在4秒前摇期间被释放时，必须安全清空引用并保留最后有效落点。"
	)
	_expect(
		too_close != null
		and outer_edge != null
		and outside != null
		and is_equal_approx(runtime.last_query_radius, 224.0),
		"边界样本与224像素共享索引查询必须完整建立。"
	)
	var saved_candidates: Array[Enemy] = []
	saved_candidates.assign(runtime.candidates)
	runtime.candidates.clear()
	mortar.combat_phase = BambooMortar.CombatPhase.IDLE
	mortar.attack_timer.stop()
	var empty_query_count := runtime.query_count
	mortar.call("_try_begin_windup")
	_expect(
		runtime.query_count == empty_query_count + 1
		and mortar.combat_phase == BambooMortar.CombatPhase.IDLE
		and not mortar.attack_timer.is_stopped()
		and is_equal_approx(
			mortar.attack_timer.time_left,
			BambooMortar.TARGET_RETRY_INTERVAL_SECONDS
		),
		"2秒计时器只能在没有目标时承担低频重试，不能成为攻击后的额外间隔。"
	)
	mortar.attack_timer.stop()
	runtime.candidates.assign(saved_candidates)
	runtime.queued_visuals.clear()
	mortar.pending_target = null
	mortar.combat_phase = BambooMortar.CombatPhase.IDLE
	mortar.attack_timer.stop()
	var operational_query_count := runtime.query_count
	mortar.call("_on_operational_started")
	_expect(
		runtime.query_count == operational_query_count + 1
		and mortar.pending_target == outer_edge
		and mortar.combat_phase == BambooMortar.CombatPhase.WINDUP
		and mortar.attack_timer.is_stopped()
		and runtime.queued_visuals.size() == 1,
		"建造完成进入可用状态时必须立即索敌并开始前摇，不能先空等2秒冷却。"
	)
	mortar.target_track_timer.stop()
	mortar.pending_target = null
	mortar.combat_phase = BambooMortar.CombatPhase.IDLE
	mortar.main_sprite.play(&"idle")
	mortar.call("_set_glow_state", false, 0)


func _test_windup_fire_and_fixed_landing(
	mortar: BambooMortar
) -> void:
	runtime.queued_visuals.clear()
	var target := enemies[2]
	target.is_dead = false
	target.global_position = Vector2(96.0, 0.0)
	mortar.muzzle_glow_light.set_night_factor(1.0)
	mortar.add_attack_interval_multiplier_modifier(9001, 0.8)
	mortar.call("_begin_authoritative_windup", target)
	var committed_supported_windup := (
		BambooMortar.WINDUP_DURATION_SECONDS * 0.8
	)
	_expect(
		mortar.combat_phase == BambooMortar.CombatPhase.WINDUP
		and mortar.main_sprite.animation == &"charge"
		and is_equal_approx(
			mortar.committed_windup_duration_seconds,
			committed_supported_windup
		)
		and is_equal_approx(mortar.main_sprite.speed_scale, 1.25)
		and mortar.muzzle_glow_light.enabled
		and is_equal_approx(
			mortar.muzzle_glow_light.night_energy,
			BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MIN
		)
		and not mortar.target_track_timer.is_stopped()
		and runtime.queued_visuals.size() == 1
		and int(runtime.queued_visuals[0].get("stage", -1))
		== BambooMortar.NETWORK_STAGE_WINDUP
		and is_equal_approx(
			float(runtime.queued_visuals[0].get(
				"committed_windup_duration_seconds",
				0.0
			)),
			committed_supported_windup
		),
		"开始攻击必须提交当前3.2秒支援蓄热、同步动画倍率并只排队一次携带提交时长的网络事件。"
	)
	mortar.remove_attack_interval_multiplier_modifier(9001)
	_expect(
		is_equal_approx(
			mortar.committed_windup_duration_seconds,
			committed_supported_windup
		)
		and is_equal_approx(mortar.main_sprite.speed_scale, 1.25),
		"蓄热轮次一旦开始，途中离开支援范围不得改写本轮已提交时长。"
	)
	mortar.last_valid_target_position = Vector2(96.0, 0.0)
	target.is_dead = true
	mortar.call("_fire_authoritative_shell")
	_expect(
		mortar.combat_phase == BambooMortar.CombatPhase.FIRING
		and mortar.main_sprite.animation == &"fire"
		and mortar.main_sprite.frame
		== BambooMortar.FIRE_LAUNCH_FRAME
		and mortar.main_sprite.position
		== BambooMortar.FIRE_RECOIL_OFFSET
		and mortar.muzzle_glow_light.enabled
		and is_equal_approx(
			mortar.muzzle_glow_light.night_energy,
			float(BambooMortar.MUZZLE_FIRE_LIGHT_ENERGIES[
				BambooMortar.FIRE_LAUNCH_FRAME
			])
		)
		and mortar.attack_timer.is_stopped()
		and mortar.fire_audio.playing
		and runtime.queued_visuals.size() == 2
		and int(runtime.queued_visuals[1].get("stage", -1))
		== BambooMortar.NETWORK_STAGE_FIRE
		and runtime.queued_visuals[1].get(
			"landing_position",
			Vector2.ZERO
		) == Vector2(96.0, 0.0)
		and is_equal_approx(
			float(runtime.queued_visuals[1].get(
				"committed_windup_duration_seconds",
				0.0
			)),
			committed_supported_windup
		),
		"目标死亡后仍须伴随砰声在可见爆闪/后坐帧向最后有效位置出膛，且出膛时不能启动额外攻击冷却。"
	)
	var active_shell := _find_active_shell()
	var expected_flight_duration := (
		clampf(
			active_shell.start_position.distance_to(
				active_shell.landing_position
			) / BambooMortarShell.PROJECTILE_SPEED_PIXELS_PER_SECOND,
			BambooMortarShell.MIN_FLIGHT_DURATION_SECONDS,
			BambooMortarShell.MAX_FLIGHT_DURATION_SECONDS
		)
		if active_shell != null
		else 0.0
	)
	_expect(
		active_shell != null
		and active_shell.landing_position == Vector2(96.0, 0.0)
		and is_equal_approx(
			active_shell.flight_duration_seconds,
			expected_flight_duration
		)
		and active_shell.flight_duration_seconds <= 0.55
		and is_equal_approx(
			active_shell.arc_height,
			clampf(
				active_shell.start_position.distance_to(
					active_shell.landing_position
				) * BambooMortarShell.ARC_HEIGHT_DISTANCE_FACTOR,
				BambooMortarShell.MIN_ARC_HEIGHT,
				BambooMortarShell.MAX_ARC_HEIGHT
			)
		)
		and active_shell.ground_shadow is Polygon2D
		and active_shell.ground_shadow.visible
		and active_shell.ground_shadow.polygon
		== PackedVector2Array([
			Vector2(-3, 0),
			Vector2(-2, -1),
			Vector2(2, -1),
			Vector2(3, 0),
			Vector2(2, 1),
			Vector2(-2, 1),
		]),
		"炮弹必须以300像素/秒和0.28至0.55秒距离限幅锁定落点，采用更低更快的抛物线，并复用场景内预建的像素地面影子。"
	)
	if active_shell != null:
		active_shell.set_physics_process(false)
		active_shell.flight_elapsed_seconds = (
			active_shell.flight_duration_seconds * 0.5
		)
		active_shell.call("_update_flight_position")
		var expected_shadow_midpoint := (
			active_shell.shadow_start_position.lerp(
				active_shell.landing_position,
				0.5
			)
		)
		var expected_projectile_apex := (
			active_shell.start_position.lerp(
				active_shell.landing_position,
				0.5
			)
			+ Vector2.UP * active_shell.arc_height
		)
		_expect(
			active_shell.global_position.is_equal_approx(
				expected_shadow_midpoint
			)
			and active_shell.visual.global_position.is_equal_approx(
				expected_projectile_apex
			)
			and is_equal_approx(
				active_shell.ground_shadow.modulate.a,
				BambooMortarShell.SHADOW_APEX_ALPHA_FACTOR
			),
			"飞行中点必须让根节点和影子沿地面前进，炮弹视觉独立到达抛物线顶点，并随高度淡化影子。"
		)
	var query_count_before_fire_finished := runtime.query_count
	mortar.call("_finish_fire_visual")
	_expect(
		runtime.query_count == query_count_before_fire_finished
		and mortar.combat_phase == BambooMortar.CombatPhase.IDLE
		and mortar.main_sprite.animation == &"idle"
		and mortar.main_sprite.position == Vector2.ZERO
		and not mortar.muzzle_glow_light.enabled
		and is_zero_approx(mortar.muzzle_glow_light.energy)
		and is_zero_approx(mortar.muzzle_glow_light.night_energy),
		"开火动画结束时必须先完整复位主体和炮口光，并把下一轮索敌放到安全的延迟调用点。"
	)
	await process_frame
	_expect(
		runtime.query_count == query_count_before_fire_finished + 1
		and mortar.combat_phase == BambooMortar.CombatPhase.WINDUP
		and mortar.main_sprite.animation == &"charge"
		and is_equal_approx(
			mortar.committed_windup_duration_seconds,
			BambooMortar.WINDUP_DURATION_SECONDS
		)
		and is_equal_approx(mortar.main_sprite.speed_scale, 1.0)
		and mortar.muzzle_glow_light.enabled
		and is_equal_approx(
			mortar.muzzle_glow_light.night_energy,
			BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MIN
		)
		and mortar.attack_timer.is_stopped(),
		"安全延迟调用必须立即开始下一次4秒前摇，不能再插入2秒攻击间隔。"
	)
	mortar.target_track_timer.stop()
	mortar.pending_target = null
	mortar.combat_phase = BambooMortar.CombatPhase.IDLE
	mortar.main_sprite.play(&"idle")
	mortar.call("_set_glow_state", false, 0)
	mortar.call(
		"_apply_muzzle_light_state",
		BambooMortar.MuzzleLightPhase.OFF,
		0
	)
	mortar.muzzle_glow_light.set_night_factor(0.0)
	await _finish_active_shells()


func _test_shell_duration_and_late_join(
	mortar: BambooMortar
) -> void:
	var pool := runtime.session_object_pool
	var start := Vector2(12.0, 18.0)
	var short_landing := start + Vector2(24.0, 0.0)
	var short_shell := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(short_shell != null, "短程飞行测试必须成功租用炮弹。")
	if short_shell != null:
		short_shell.setup(
			start,
			short_landing,
			BambooMortarShell.DEFAULT_INNER_DAMAGE,
			BambooMortarShell.DEFAULT_OUTER_DAMAGE,
			false,
			0,
			0.0
		)
		_expect(
			is_equal_approx(
				short_shell.flight_duration_seconds,
				BambooMortarShell.MIN_FLIGHT_DURATION_SECONDS
			),
			"近距离炮弹必须使用0.28秒下限，既加速又保留可读的飞行帧。"
		)
		short_shell.call("_impact")
		_expect(
			short_shell.impact_audio.playing,
			"正常落点必须立即播放迫击炮爆炸音效。"
		)
		short_shell.call("_on_visual_animation_finished")
		_expect(
			bool(
				short_shell.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
			and bool(
				short_shell.get("_explosion_completion_pending")
			)
			and not short_shell.visual.visible
			and short_shell.impact_audio.playing,
			"爆炸画面结束后必须先隐藏画面并等待长音效完成，不能提前回池截断声音。"
		)
		_finish_shell_audio(short_shell)
	await physics_frame
	await physics_frame

	var far_landing := start + Vector2(300.0, 0.0)
	var far_shell := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(far_shell != null, "远程飞行测试必须成功复用炮弹。")
	if far_shell != null:
		far_shell.setup(
			start,
			far_landing,
			BambooMortarShell.DEFAULT_INNER_DAMAGE,
			BambooMortarShell.DEFAULT_OUTER_DAMAGE,
			false,
			0,
			0.0
		)
		_expect(
			is_equal_approx(
				far_shell.flight_duration_seconds,
				BambooMortarShell.MAX_FLIGHT_DURATION_SECONDS
			),
			"远距离炮弹必须受0.55秒上限约束，不能恢复为长时间滞空。"
		)
		far_shell.call("_impact")
		_finish_shell_effect(far_shell)
	await physics_frame
	await physics_frame

	var late_landing := start + Vector2(160.0, 0.0)
	var late_flight_duration := (
		BambooMortarShell.get_flight_duration_seconds(
			start,
			late_landing
		)
	)
	var late_elapsed := (
		late_flight_duration
		+ BambooMortarShell.EXPLOSION_DURATION_SECONDS * 0.25
	)
	var late_shell := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(late_shell != null, "延迟加入爆炸恢复测试必须成功复用炮弹。")
	if late_shell != null:
		late_shell.setup(
			start,
			late_landing,
			BambooMortarShell.DEFAULT_INNER_DAMAGE,
			BambooMortarShell.DEFAULT_OUTER_DAMAGE,
			false,
			0,
			late_elapsed
		)
		_expect(
			bool(late_shell.get("_has_impacted"))
			and late_shell.global_position == late_landing
			and late_shell.visual.position == Vector2.ZERO
			and late_shell.visual.animation == &"explosion"
			and not late_shell.ground_shadow.visible,
			"客户端晚到飞行事件若已进入爆炸阶段，必须直接在落点恢复爆炸并隐藏地影。"
		)
		_finish_shell_effect(late_shell)
	await physics_frame
	await physics_frame

	var snapshot_action_id := 8801
	var snapshot_landing := start + Vector2(120.0, 16.0)
	var snapshot_total_duration := (
		BambooMortarShell.get_total_visual_duration_seconds(
			start,
			snapshot_landing
		)
	)
	mortar.set("_last_projectile_action_id", snapshot_action_id)
	mortar.set("_last_projectile_spawn_position", start)
	mortar.set(
		"_last_projectile_landing_position",
		snapshot_landing
	)
	mortar.set(
		"_last_projectile_started_at_seconds",
		Time.get_ticks_msec() / 1000.0 - 0.1
	)
	var active_snapshot := mortar.export_multiplayer_runtime_state()
	mortar.set(
		"_last_projectile_started_at_seconds",
		Time.get_ticks_msec() / 1000.0
		- snapshot_total_duration
		- 0.01
	)
	var expired_snapshot := mortar.export_multiplayer_runtime_state()
	_expect(
		int(active_snapshot.get("projectile_action_id", 0))
		== snapshot_action_id
		and active_snapshot.get(
			"projectile_landing_position",
			Vector2.ZERO
		) == snapshot_landing
		and not expired_snapshot.has("projectile_action_id"),
		"运行时快照必须按本次端点的实际总时长保留飞行事件，并在视觉结束后立即停止同步。"
	)
	mortar.set("_last_projectile_action_id", 0)
	mortar.set("_last_projectile_started_at_seconds", -INF)
	mortar.set("_last_projectile_spawn_position", Vector2.ZERO)
	mortar.set("_last_projectile_landing_position", Vector2.ZERO)

	var metrics_before_expired := pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var expired_shell := mortar.call(
		"_spawn_shell",
		start,
		late_landing,
		false,
		BambooMortarShell.get_total_visual_duration_seconds(
			start,
			late_landing
		)
	) as BambooMortarShell
	var metrics_after_expired := pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	_expect(
		expired_shell == null
		and int(metrics_after_expired.get("in_use", -1))
		== int(metrics_before_expired.get("in_use", -2))
		and int(metrics_after_expired.get("created", -1))
		== int(metrics_before_expired.get("created", -2)),
		"已超过实际总时长的联机事件必须在租池前丢弃，不能短暂激活或扩容炮弹。"
	)


func _test_explosion_damage_boundaries() -> void:
	await _clear_enemies()
	var inner_edge := _spawn_enemy(Vector2(16.0, 0.0))
	var outer_start := _spawn_enemy(Vector2(16.25, 0.0))
	var outer_edge := _spawn_enemy(Vector2(32.0, 0.0))
	var outside := _spawn_enemy(Vector2(32.25, 0.0))
	runtime.candidates.assign(enemies)
	runtime.damage_records.clear()
	var queries_before := runtime.query_count
	var shell := runtime.acquire_session_object(
		SHELL_SCENE,
		false
	) as BambooMortarShell
	_expect(shell != null, "爆炸边界测试必须能从共享对象池租用炮弹。")
	if shell == null:
		return
	shell.setup(Vector2.ZERO, Vector2.ZERO, 140, 70, true, 9001, 0.0)
	shell.call("_impact")
	_expect(
		runtime.query_count == queries_before + 1,
		"一次爆炸必须且只能执行一次半径32的共享索引查询。"
	)
	var damage_by_enemy: Dictionary[int, int] = {}
	for record in runtime.damage_records:
		var enemy := record.get("enemy") as Enemy
		if enemy != null:
			damage_by_enemy[enemy.get_instance_id()] = int(
				record.get("damage", 0)
			)
		_expect(
			int(record.get("damage_type", -1))
			== EnemyConfig.DamageType.PHYSICAL,
			"迫击炮所有爆炸伤害必须标记为物理伤害。"
		)
	_expect(
		damage_by_enemy.get(inner_edge.get_instance_id(), 0) == 140
		and damage_by_enemy.get(outer_start.get_instance_id(), 0) == 70
		and damage_by_enemy.get(outer_edge.get_instance_id(), 0) == 70
		and not damage_by_enemy.has(outside.get_instance_id())
		and damage_by_enemy.size() == 3,
		"0至16像素必须造成140伤害，(16,32]造成70伤害，32外不得受伤。"
	)
	_finish_shell_effect(shell)
	await physics_frame
	await physics_frame


func _test_physical_defense_settlement() -> void:
	await _clear_enemies()
	var armored := (
		ARMORED_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	)
	_expect(armored != null, "物理防御实结算必须成功实例化硬壳敌人。")
	if armored == null:
		return
	runtime.add_child(armored)
	armored.global_position = Vector2.ZERO
	armored.setup(ARMORED_ENEMY_CONFIG, null, null, runtime)
	armored.set_process(false)
	armored.set_physics_process(false)
	if armored.touch_damage_area != null:
		armored.touch_damage_area.set_deferred("monitoring", false)
		armored.touch_damage_area.set_deferred("monitorable", false)
	enemies.append(armored)
	runtime.candidates.assign(enemies)
	runtime.damage_records.clear()
	runtime.apply_real_damage = true
	var shell := runtime.acquire_session_object(
		SHELL_SCENE,
		false
	) as BambooMortarShell
	_expect(shell != null, "物理防御实结算必须能租用迫击炮弹。")
	if shell != null:
		shell.setup(
			Vector2.ZERO,
			Vector2.ZERO,
			140,
			70,
			true,
			9100,
			0.0
		)
		shell.call("_impact")
	_expect(
		armored.current_health == ARMORED_ENEMY_CONFIG.max_health - 137
		and armored.last_damage_taken == 137
		and runtime.damage_records.size() == 1
		and int(
			runtime.damage_records[0].get("damage_type", -1)
			if not runtime.damage_records.is_empty()
			else -1
		) == EnemyConfig.DamageType.PHYSICAL,
		"140点中心物理伤害命中3点物防敌人时必须且只能扣除137点生命。"
	)
	runtime.apply_real_damage = false
	if shell != null:
		_finish_shell_effect(shell)
	await physics_frame
	await physics_frame


func _test_proxy_actions_and_runtime_state(
	authority: BambooMortar,
	proxy: BambooMortar
) -> void:
	proxy.muzzle_glow_light.set_night_factor(1.0)
	proxy.main_sprite.position = BambooMortar.FIRE_RECOIL_OFFSET
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_WINDUP,
		17,
		proxy.muzzle.global_position,
		Vector2(88.0, 0.0),
		1.0,
		BambooMortar.WINDUP_DURATION_SECONDS * 0.8
	)
	var first_frame := proxy.main_sprite.frame
	var first_charge_progress := smoothstep(
		0.0,
		1.0,
		float(first_frame) / float(BambooMortar.WINDUP_FRAME_COUNT - 1)
	)
	var expected_first_charge_energy := lerpf(
		BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MIN,
		BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MAX,
		first_charge_progress
	)
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_WINDUP,
		17,
		proxy.muzzle.global_position,
		Vector2(120.0, 0.0),
		0.0,
		BambooMortar.WINDUP_DURATION_SECONDS * 0.8
	)
	_expect(
		first_frame == 2
		and proxy.main_sprite.frame == first_frame
		and proxy.main_sprite.position
		== BambooMortar.MAIN_SPRITE_REST_POSITION
		and is_equal_approx(proxy.main_sprite.speed_scale, 1.25)
		and is_equal_approx(
			proxy.committed_windup_duration_seconds,
			BambooMortar.WINDUP_DURATION_SECONDS * 0.8
		)
		and proxy.muzzle_glow_light.enabled
		and is_equal_approx(
			proxy.muzzle_glow_light.night_energy,
			expected_first_charge_energy
		)
		and proxy.latest_proxy_action_id == 17,
		"客户端必须复位旧后坐位移、按Host时间快进至对应蓄热帧，并拒绝重复阶段回滚。"
	)
	proxy.call("_on_main_sprite_animation_finished")
	_expect(
		proxy.main_sprite.animation == &"fire"
		and proxy.main_sprite.frame == 0
		and is_equal_approx(
			proxy.muzzle_glow_light.night_energy,
			float(BambooMortar.MUZZLE_FIRE_LIGHT_ENERGIES[0])
		)
		and proxy.combat_phase == BambooMortar.CombatPhase.FIRING,
		"客户端蓄热结束后必须先显示与Host一致的fire_0预备帧，不能停在charge末帧等待出膛事件。"
	)
	var pre_fire_shell_count := _count_active_shells()
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_FIRE,
		17,
		proxy.muzzle.global_position,
		Vector2(88.0, 0.0),
		0.0,
		BambooMortar.WINDUP_DURATION_SECONDS
	)
	_expect(
		proxy.latest_proxy_stage == BambooMortar.NETWORK_STAGE_WINDUP
		and _count_active_shells() == pre_fire_shell_count
		and is_equal_approx(
			proxy.committed_windup_duration_seconds,
			BambooMortar.WINDUP_DURATION_SECONDS * 0.8
		),
		"同一多人动作的出膛阶段不得改写前摇阶段已提交的3.2秒时长。"
	)
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_FIRE,
		17,
		proxy.muzzle.global_position,
		Vector2(88.0, 0.0),
		0.0,
		BambooMortar.WINDUP_DURATION_SECONDS * 0.8
	)
	var proxy_shell_count := _count_active_shells()
	_expect(
		proxy.main_sprite.animation == &"fire"
		and proxy.main_sprite.frame
		== BambooMortar.FIRE_LAUNCH_FRAME
		and is_equal_approx(
			proxy.muzzle_glow_light.night_energy,
			float(BambooMortar.MUZZLE_FIRE_LIGHT_ENERGIES[
				BambooMortar.FIRE_LAUNCH_FRAME
			])
		)
		and proxy.combat_phase == BambooMortar.CombatPhase.FIRING,
		"客户端收到出膛事件时必须显示对应爆闪/后坐帧，不能直接跳回idle。"
	)
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_FIRE,
		17,
		proxy.muzzle.global_position,
		Vector2(88.0, 0.0),
		0.0,
		BambooMortar.WINDUP_DURATION_SECONDS
	)
	_expect(
		_count_active_shells() == proxy_shell_count
		and proxy.latest_proxy_stage
		== BambooMortar.NETWORK_STAGE_FIRE,
		"同一action_id的重复出膛记录不得生成第二枚客户端视觉炮弹。"
	)
	authority.combat_phase = BambooMortar.CombatPhase.WINDUP
	authority.next_authoritative_action_id = 23
	authority.committed_windup_duration_seconds = (
		BambooMortar.WINDUP_DURATION_SECONDS * 0.8
	)
	authority.last_valid_target_position = Vector2(112.0, 8.0)
	authority.set(
		"_windup_started_at_seconds",
		Time.get_ticks_msec() / 1000.0 - 1.5
	)
	authority.set("_last_projectile_action_id", 22)
	authority.set(
		"_last_projectile_started_at_seconds",
		Time.get_ticks_msec() / 1000.0 - 0.1
	)
	authority.set(
		"_last_projectile_spawn_position",
		authority.muzzle.global_position
	)
	authority.set(
		"_last_projectile_landing_position",
		Vector2(104.0, 8.0)
	)
	var snapshot := authority.export_multiplayer_runtime_state()
	var overlapping_shell_count := _count_active_shells()
	var fresh_proxy := _create_mortar(true, 703)
	if fresh_proxy != null:
		fresh_proxy.muzzle_glow_light.set_night_factor(1.0)
		fresh_proxy.apply_multiplayer_runtime_state(
			snapshot,
			Time.get_ticks_msec() / 1000.0
		)
		_expect(
			fresh_proxy.latest_proxy_action_id == 23
			and fresh_proxy.combat_phase
			== BambooMortar.CombatPhase.WINDUP
			and fresh_proxy.main_sprite.frame >= 2
			and is_equal_approx(fresh_proxy.main_sprite.speed_scale, 1.25)
			and is_equal_approx(
				fresh_proxy.committed_windup_duration_seconds,
				BambooMortar.WINDUP_DURATION_SECONDS * 0.8
			)
			and fresh_proxy.muzzle_glow_light.enabled
			and fresh_proxy.muzzle_glow_light.night_energy
			> BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MIN
			and int(
				fresh_proxy.get("_latest_proxy_shell_action_id")
			) == 22
			and _count_active_shells()
			== overlapping_shell_count + 1,
			"中途加入的客户端必须同时恢复当前前摇与上一枚仍在飞行的炮弹。"
		)
	var dropped_fire_proxy := _create_mortar(true, 704)
	if dropped_fire_proxy != null:
		dropped_fire_proxy.muzzle_glow_light.set_night_factor(1.0)
		dropped_fire_proxy.play_multiplayer_action(
			BambooMortar.NETWORK_STAGE_WINDUP,
			23,
			dropped_fire_proxy.muzzle.global_position,
			Vector2(112.0, 8.0),
			1.5,
			BambooMortar.WINDUP_DURATION_SECONDS * 0.8
		)
		var dropped_fire_shell_count := _count_active_shells()
		dropped_fire_proxy.apply_multiplayer_runtime_state(
			snapshot,
			Time.get_ticks_msec() / 1000.0
		)
		_expect(
			dropped_fire_proxy.latest_proxy_action_id == 23
			and dropped_fire_proxy.latest_proxy_stage
			== BambooMortar.NETWORK_STAGE_WINDUP
			and int(
				dropped_fire_proxy.get(
					"_latest_proxy_shell_action_id"
				)
			) == 22
			and dropped_fire_proxy.main_sprite.animation == &"charge"
			and dropped_fire_proxy.muzzle_glow_light.enabled
			and dropped_fire_proxy.muzzle_glow_light.night_energy
			> BambooMortar.MUZZLE_CHARGE_LIGHT_ENERGY_MIN
			and _count_active_shells()
			== dropped_fire_shell_count + 1,
			"已收到新前摇但漏收旧出膛事件的客户端，必须由快照补回旧炮弹且不能回滚主体和炮口光。"
		)
		dropped_fire_proxy.apply_multiplayer_runtime_state(
			snapshot,
			Time.get_ticks_msec() / 1000.0
		)
		_expect(
			_count_active_shells()
			== dropped_fire_shell_count + 1,
			"重复快照不得为同一旧action补生成第二枚炮弹。"
		)
	var newer_action_proxy := _create_mortar(true, 705)
	if newer_action_proxy != null:
		newer_action_proxy.play_multiplayer_action(
			BambooMortar.NETWORK_STAGE_WINDUP,
			24,
			newer_action_proxy.muzzle.global_position,
			Vector2(128.0, 8.0),
			0.5,
			BambooMortar.WINDUP_DURATION_SECONDS
		)
		var stale_snapshot_shell_count := _count_active_shells()
		newer_action_proxy.apply_multiplayer_runtime_state(
			snapshot,
			Time.get_ticks_msec() / 1000.0
		)
		_expect(
			newer_action_proxy.latest_proxy_action_id == 24
			and newer_action_proxy.latest_proxy_stage
			== BambooMortar.NETWORK_STAGE_WINDUP
			and int(
				newer_action_proxy.get(
					"_latest_proxy_shell_action_id"
				)
			) == 0
			and _count_active_shells()
			== stale_snapshot_shell_count,
			"客户端推进到更新action后，旧快照不得倒灌已经过期的飞行炮弹。"
		)
	await _finish_active_shells()


func _test_pool_reuse() -> void:
	var pool := runtime.session_object_pool
	var before := pool.get_metrics(SHELL_SCENE.resource_path)
	var first := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(first != null, "对象池复用测试必须成功租用炮弹。")
	if first == null:
		return
	var first_id := first.get_instance_id()
	first.setup(Vector2.ZERO, Vector2(80.0, 0.0), 140, 70, false, 0, 0.0)
	first.call("_impact")
	_finish_shell_effect(first)
	await physics_frame
	await physics_frame
	var second := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(
		second != null
		and second.get_instance_id() == first_id
		and not second.get("_has_impacted")
		and second.inner_damage == 140
		and second.outer_damage == 70,
		"炮弹租约必须复用同一实例并完整复位命中、伤害和动画状态。"
	)
	if second != null:
		second.setup(Vector2.ZERO, Vector2(80.0, 0.0), 140, 70, false, 0, 0.0)
		second.call("_impact")
		_finish_shell_effect(second)
	await physics_frame
	await physics_frame
	var after := pool.get_metrics(SHELL_SCENE.resource_path)
	_expect(
		int(after.get("created", -1))
		== int(before.get("created", -2))
		and int(after.get("in_use", -1)) == 0
		and int(after.get("pending_release", -1)) == 0,
		"预热后的重复租约不得新增节点，测试结束必须归还全部炮弹。"
	)


func _spawn_enemy(position: Vector2) -> Enemy:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "边界测试敌人必须成功实例化。")
	if enemy == null:
		return null
	runtime.add_child(enemy)
	enemy.global_position = position
	enemy.is_dead = false
	enemy.set_process(false)
	enemy.set_physics_process(false)
	if enemy.touch_damage_area != null:
		enemy.touch_damage_area.set_deferred("monitoring", false)
		enemy.touch_damage_area.set_deferred("monitorable", false)
	enemies.append(enemy)
	return enemy


func _clear_enemies() -> void:
	runtime.candidates.clear()
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
	enemies.clear()
	await process_frame


func _find_active_shell() -> BambooMortarShell:
	for child in runtime.session_object_pool.get_children():
		var shell := child as BambooMortarShell
		if (
			shell != null
			and bool(
				shell.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
		):
			return shell
	return null


func _count_active_shells() -> int:
	var count := 0
	for child in runtime.session_object_pool.get_children():
		if (
			child is BambooMortarShell
			and bool(
				child.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
		):
			count += 1
	return count


func _finish_active_shells() -> void:
	for child in runtime.session_object_pool.get_children():
		var shell := child as BambooMortarShell
		if (
			shell == null
			or not bool(
				shell.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
		):
			continue
		if not bool(shell.get("_has_impacted")):
			shell.call("_impact")
		_finish_shell_effect(shell)
	await physics_frame
	await physics_frame


func _finish_shell_effect(shell: BambooMortarShell) -> void:
	if shell == null:
		return
	shell.call("_on_visual_animation_finished")
	_finish_shell_audio(shell)


func _finish_shell_audio(shell: BambooMortarShell) -> void:
	if (
		shell == null
		or not bool(shell.get("_explosion_completion_pending"))
	):
		return
	EXPLOSION_AUDIO_LIMITER.stop(shell.impact_audio)
	shell.call("_on_impact_audio_preempted")


func _cleanup() -> void:
	await _finish_active_shells()
	await _clear_enemies()
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
