extends SceneTree

const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const FLASH_POOL_SCENE := preload(
	"res://scene/lighting/night_vfx_flash_pool.tscn"
)
const LIGHTNING_CHAIN_VFX_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_lightning_vfx.tscn"
)
const SELF_LIT_PROJECTILE_SCENES := [
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn",
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn",
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn",
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn",
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn",
	"res://scene/player/tiyi/tiyi_sniper_bullet.tscn",
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn",
	"res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn",
	"res://scene/collectible_sakura_rocket.tscn",
	"res://scene/plant_defense/bamboo_mortar_shell.tscn",
]
const PROJECTILE_HALO_SCENE_COUNTS := {
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn": 3,
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn": 3,
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn": 1,
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn": 1,
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn": 1,
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn": 1,
	"res://scene/player/tiyi/tiyi_sniper_bullet.tscn": 1,
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn": 1,
	"res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn": 1,
	"res://scene/collectible_sakura_rocket.tscn": 1,
	"res://scene/plant_defense/bamboo_mortar_shell.tscn": 1,
	"res://scene/collectible_arrow_projectile.tscn": 1,
	"res://scene/plant_defense/agave_cannonball.tscn": 1,
	"res://scene/plant_defense/corn_machine_gun.tscn": 1,
	"res://scene/enemy/capoo/capoo_smg.tscn": 1,
}
const RAPID_PROJECTILE_MATERIAL_PATH := (
	"res://resources/shader/rapid_projectile_single_pass.tres"
)
const FROST_PROJECTILE_MATERIAL_PATH := (
	"res://resources/shader/frost_projectile_single_pass.tres"
)
const TANGO_LASER_PROJECTILE_MATERIAL_PATH := (
	"res://resources/shader/tango_laser_bullet_single_pass.tres"
)
const SINGLE_PASS_PROJECTILE_SCENE_MATERIALS := {
	"res://scene/bullet.tscn": RAPID_PROJECTILE_MATERIAL_PATH,
	"res://scene/player/tango/tango_laser_bullet.tscn": TANGO_LASER_PROJECTILE_MATERIAL_PATH,
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn": RAPID_PROJECTILE_MATERIAL_PATH,
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn": RAPID_PROJECTILE_MATERIAL_PATH,
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn": RAPID_PROJECTILE_MATERIAL_PATH,
	"res://scene/enemy/capoo/capoo_smg_bullet.tscn": RAPID_PROJECTILE_MATERIAL_PATH,
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn": FROST_PROJECTILE_MATERIAL_PATH,
}
const PREBUILT_SPATIAL_HALO_SCENES := [
	"res://scene/boss/linglan/linglan_skill3_light_orb.tscn",
	"res://scene/boss/linglan/linglan_skill4_light_orb.tscn",
]
const SHARED_LIGHT_EXPLOSION_SCENES := [
	"res://scene/enemy/capoo/capoo_rpg_explosion.tscn",
	"res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn",
	"res://scene/player/weishidaier/weishidaier_skill1_explosion.tscn",
	"res://scene/collectible_sakura_explosion.tscn",
	"res://scene/boss/linglan/linglan_skill2_sakura_explosion.tscn",
	"res://scene/player/tiyi/tiyi_sniper_hit_effect.tscn",
	"res://scene/plant_defense/bamboo_mortar_shell.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_bomber.tscn",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_purple_bomber.tscn",
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn",
]
const POOLED_ANIMATED_EMISSION_SCENES := [
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn",
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn",
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn",
	"res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn",
	"res://scene/collectible_sakura_rocket.tscn",
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(320, 240)
	root.content_scale_size = Vector2i(320, 240)

	var decoy_world := Node2D.new()
	decoy_world.name = "DecoyNightCombatVfxWorld"
	root.add_child(decoy_world)
	var decoy_pool := FLASH_POOL_SCENE.instantiate() as NightVfxFlashPool
	decoy_world.add_child(decoy_pool)

	var world := Node2D.new()
	world.name = "NightCombatVfxSmokeWorld"
	root.add_child(world)
	current_scene = world

	var controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	world.add_child(controller)
	var pool := FLASH_POOL_SCENE.instantiate() as NightVfxFlashPool
	world.add_child(pool)
	var source := Node2D.new()
	source.name = "EffectSource"
	world.add_child(source)
	var camera := Camera2D.new()
	camera.position = Vector2(160.0, 120.0)
	camera.enabled = true
	world.add_child(camera)
	await process_frame
	await process_frame

	_verify_pool_structure(pool)
	_verify_day_night_envelope(controller, pool)
	_verify_pool_budget(pool, source, decoy_pool)
	_verify_scene_structure()
	_verify_emission_shader()
	_verify_rapid_projectile_single_pass()
	await _verify_pooled_overlay_sync(world)

	current_scene = null
	world.queue_free()
	decoy_world.queue_free()
	await process_frame
	if failures.is_empty():
		print("NIGHT_COMBAT_VFX_SMOKE_TEST_PASSED")
		quit(0)
		return
	print("NIGHT_COMBAT_VFX_SMOKE_TEST_FAILED count=%d" % failures.size())
	quit(1)


func _verify_pool_structure(pool: NightVfxFlashPool) -> void:
	_expect(pool.get_capacity() == 8, "夜间战斗闪光池必须固定为8盏灯。")
	_expect(pool.get_child_count() == 8, "闪光池场景必须预置且仅预置8个槽位。")
	for child in pool.get_children():
		var flash := child as NightVfxFlash2D
		_expect(flash != null, "闪光池的每个直接子节点都必须是NightVfxFlash2D。")
		if flash == null:
			continue
		_expect(not flash.shadow_enabled, "战斗闪光不得开启昂贵的2D阴影。")
		_expect(not flash.auto_play, "共享池内的闪光节点不得自动播放。")


func _verify_day_night_envelope(
	controller: DayNightController,
	pool: NightVfxFlashPool
) -> void:
	controller.set_night_factor_immediate(0.0)
	var accepted := pool.request_flash(
		Vector2(160.0, 120.0),
		Color(1.0, 0.55, 0.22, 1.0),
		1.0,
		0.8,
		0.02,
		0.03,
		0.12,
		2
	)
	var flash := pool.get_child(0) as NightVfxFlash2D
	_expect(accepted and flash.is_flash_active(), "白天请求仍须推进短暂包络。")
	_expect(not flash.enabled and is_zero_approx(flash.energy), "白天真实PointLight必须关闭。")

	controller.set_night_factor_immediate(1.0)
	_expect(flash.enabled and flash.energy > 0.0, "同一闪光在夜间必须照亮世界。")
	_expect(
		flash.texture_scale >= 0.5,
		"爆炸闪光起始范围必须能越过爆炸贴图本体。"
	)
	flash.stop_flash()
	_expect(not flash.enabled and is_zero_approx(flash.energy), "停止包络必须立即关灯。")


func _verify_pool_budget(
	pool: NightVfxFlashPool,
	source: Node,
	decoy_pool: NightVfxFlashPool
) -> void:
	for child in pool.get_children():
		(child as NightVfxFlash2D).stop_flash()
	for request_index in range(8):
		_expect(
			pool.request_flash(
				Vector2(120.0 + request_index * 4.0, 120.0),
				Color.WHITE,
				0.8,
				0.35,
				0.01,
				0.02,
				0.2,
				2
			),
			"可见范围内前8个闪光请求都必须获得槽位。"
		)
	_expect(pool.get_active_flash_count() == 8, "活跃真实灯数量不得超过固定预算。")
	_expect(
		not pool.request_flash(
			Vector2(160.0, 120.0),
			Color.WHITE,
			0.8,
			0.35,
			0.01,
			0.02,
			0.2,
			1
		),
		"低优先级请求不得抢占更高优先级的满池。"
	)
	_expect(
		pool.request_flash(
			Vector2(160.0, 120.0),
			Color.WHITE,
			1.0,
			0.6,
			0.01,
			0.02,
			0.2,
			3
		),
		"高优先级大爆炸必须能抢占较低优先级槽位。"
	)
	_expect(pool.get_active_flash_count() == 8, "抢占后仍只能有8盏真实灯。")
	_expect(
		NightVfxFlashPool.find_for(source) == pool,
		"特效必须能在同一世界分支中找到共享闪光池。"
	)

	for child in pool.get_children():
		(child as NightVfxFlash2D).stop_flash()
	_expect(pool.get_active_flash_count() == 0, "释放后闪光池不得留下活跃灯。")
	_expect(
		pool.request_flash(
			Vector2(430.0, 120.0),
			Color.WHITE,
			0.8,
			1.0
		),
		"中心略微离屏但光圈仍覆盖画面的爆炸不得被裁掉。"
	)
	(pool.get_child(0) as NightVfxFlash2D).stop_flash()
	_expect(
		not pool.request_flash(
			Vector2(1000.0, 120.0),
			Color.WHITE,
			0.8,
			1.0
		),
		"远离画面的爆炸不得占用共享灯槽。"
	)

	# MpGame keeps replicated effects on itself while the actual gameplay scene
	# (and therefore the light pool) is an embedded child. The lookup must cross
	# that sibling/descendant boundary without recursively scanning the tree.
	var world := source.get_parent()
	var embedded_game := Node2D.new()
	embedded_game.name = "EmbeddedMultiplayerGame"
	world.add_child(embedded_game)
	pool.reparent(embedded_game)
	_expect(
		NightVfxFlashPool.find_for(source) == pool,
		"多人根节点特效必须能找到内嵌游戏场景中的共享闪光池。"
	)
	var decoy_world := decoy_pool.get_parent()
	pool.reparent(decoy_world)
	_expect(
		NightVfxFlashPool.find_for(source) == null,
		"当前场景没有共享池时不得回退到其他世界或Viewport的诱饵池。"
	)
	pool.reparent(world)
	embedded_game.free()


func _verify_scene_structure() -> void:
	var lightning_chain := LIGHTNING_CHAIN_VFX_SCENE.instantiate() as Node2D
	_expect(
		lightning_chain != null
		and lightning_chain.get_child_count() == 0
		and _count_point_lights(lightning_chain) == 0,
		"雷电链必须保持无物理节点、无逐目标PointLight的单CanvasItem结构。"
	)
	if lightning_chain != null:
		var lightning_material := lightning_chain.material as CanvasItemMaterial
		_expect(
			lightning_material != null
			and lightning_material.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD
			and lightning_material.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED,
			"雷电链必须复用不受夜色二次压暗的加色自发光材质。"
		)
		lightning_chain.free()

	for scene_path in SELF_LIT_PROJECTILE_SCENES:
		var instance := _instantiate_scene(scene_path)
		if instance == null:
			continue
		_expect(
			_count_named_emission_overlays(instance) > 0,
			"高频弹体缺少自发光叠层：%s" % scene_path
		)
		_expect(
			_count_point_lights(instance) == 0,
			"高频弹体不得各自携带PointLight2D：%s" % scene_path
		)
		instance.free()

	for scene_path in PROJECTILE_HALO_SCENE_COUNTS:
		var instance := _instantiate_scene(scene_path)
		if instance == null:
			continue
		var halos: Array[Node] = []
		_find_named_nodes(instance, &"ProjectileHalo", halos)
		_expect(
			halos.size() == int(PROJECTILE_HALO_SCENE_COUNTS[scene_path]),
			"弹体柔光数量不正确：%s" % scene_path
		)
		for halo in halos:
			_verify_projectile_halo(halo, scene_path)
		_expect(
			_count_point_lights(instance) == 0,
			"弹体柔光不得使用逐弹PointLight2D：%s" % scene_path
		)
		instance.free()

	for scene_path in PREBUILT_SPATIAL_HALO_SCENES:
		var instance := _instantiate_scene(scene_path)
		if instance == null:
			continue
		var outer_halos: Array[Node] = []
		_find_named_nodes(instance, &"OuterHalo", outer_halos)
		_expect(
			outer_halos.size() > 0,
			"既有光球必须保留自身的多层空间柔光：%s" % scene_path
		)
		_expect(
			_count_point_lights(instance) == 0,
			"既有光球不得使用逐弹PointLight2D：%s" % scene_path
		)
		instance.free()

	for scene_path in SHARED_LIGHT_EXPLOSION_SCENES:
		var instance := _instantiate_scene(scene_path)
		if instance == null:
			continue
		_expect(
			_count_named_emission_overlays(instance) > 0,
			"爆炸/冲击特效缺少可见的发光核心：%s" % scene_path
		)
		_expect(
			_count_point_lights(instance) == 0,
			"爆炸场景必须复用共享光池，不能内置常驻灯：%s" % scene_path
		)
		instance.free()

	_expect(
		_packed_scene_has_node("res://scene/game.tscn", &"NightVfxFlashPool"),
		"普通模式世界必须直接预置共享夜间闪光池。"
	)
	_expect(
		_packed_scene_has_node(
			"res://scene/game_tower_defense.tscn",
			&"NightVfxFlashPool"
		),
		"塔防世界必须直接预置共享夜间闪光池。"
	)


func _verify_emission_shader() -> void:
	var shader := load(
		"res://resources/shader/night_vfx_emission_mask.gdshader"
	) as Shader
	_expect(shader != null, "亮区遮罩shader必须可以加载。")
	if shader == null:
		return
	_expect(
		shader.code.contains("vec4 source = COLOR"),
		"亮区遮罩必须继承CanvasItem的modulate/self_modulate。"
	)
	_expect(
		shader.code.contains("render_mode blend_add, unshaded"),
		"亮区遮罩必须使用不受CanvasModulate压暗的加色自发光。"
	)


func _verify_rapid_projectile_single_pass() -> void:
	var shared_material := load(RAPID_PROJECTILE_MATERIAL_PATH) as ShaderMaterial
	_expect(shared_material != null, "高频弹体共享单通道发光材质必须可以加载。")
	if shared_material == null:
		return
	_expect(
		not shared_material.resource_local_to_scene,
		"高频弹体单通道发光材质必须跨弹体共享，禁止逐弹复制。"
	)
	var shader := shared_material.shader
	_expect(shader != null, "高频弹体单通道发光材质缺少shader。")
	if shader != null:
		_expect(
			shader.code.contains("render_mode unshaded"),
			"高频弹体单通道材质必须保持夜间自发光。"
		)
		_expect(
			shader.code.contains("source.rgb + tinted_source * emission_gain"),
			"高频弹体单通道材质必须在保留清晰本体的同时输出HDR高光。"
		)
	var emission_strength := float(
		shared_material.get_shader_parameter(&"emission_strength")
	)
	_expect(
		emission_strength >= 0.3 and emission_strength <= 0.9,
		"高频弹体单通道发光强度必须保持克制，避免弹幕洗白。"
	)

	for scene_path in SINGLE_PASS_PROJECTILE_SCENE_MATERIALS:
		var expected_material := load(
			str(SINGLE_PASS_PROJECTILE_SCENE_MATERIALS[scene_path])
		) as ShaderMaterial
		_expect(expected_material != null, "单通道弹体材质必须可以加载：%s" % scene_path)
		if expected_material == null:
			continue
		_expect(
			not expected_material.resource_local_to_scene,
			"单通道弹体材质必须跨同类弹体共享：%s" % scene_path
		)
		_expect(
			expected_material.shader == shader,
			"单通道弹体必须复用已审计的自发光Shader：%s" % scene_path
		)
		var expected_strength := float(
			expected_material.get_shader_parameter(&"emission_strength")
		)
		_expect(
			expected_strength >= 0.3 and expected_strength <= 0.9,
			"单通道弹体发光强度必须保持克制：%s" % scene_path
		)
		var instance := _instantiate_scene(scene_path)
		if instance == null:
			continue
		var main_sprite := instance.get_node_or_null("AnimatedSprite2D") as CanvasItem
		if main_sprite == null:
			main_sprite = instance.get_node_or_null("Sprite2D") as CanvasItem
		if main_sprite == null:
			main_sprite = instance.get_node_or_null("DroneSprite") as CanvasItem
		_expect(main_sprite != null, "高频弹体缺少主体贴图：%s" % scene_path)
		if main_sprite != null:
			_expect(
				main_sprite.material == expected_material,
				"弹体必须直接复用对应的共享单通道材质：%s" % scene_path
			)
			var animated_sprite := main_sprite as AnimatedSprite2D
			var static_sprite := main_sprite as Sprite2D
			_expect(
				(
					animated_sprite != null
					and animated_sprite.sprite_frames != null
					and animated_sprite.sprite_frames.has_animation(&"fly")
				)
				or (static_sprite != null and static_sprite.texture != null),
				"单通道优化不得替换或破坏高频弹体本体：%s" % scene_path
			)
			_expect(
				main_sprite.get_node_or_null("ProjectileHalo") == null
				and main_sprite.get_node_or_null("EmissionOverlay") == null,
				"高频弹体不得保留逐弹Halo或EmissionOverlay：%s" % scene_path
			)
		_expect(
			_count_point_lights(instance) == 0,
			"高频弹体不得引入逐弹PointLight2D：%s" % scene_path
		)
		instance.free()


func _verify_pooled_overlay_sync(world: Node2D) -> void:
	for scene_path in POOLED_ANIMATED_EMISSION_SCENES:
		var instance := _instantiate_scene(scene_path)
		if instance == null:
			continue
		instance.process_mode = Node.PROCESS_MODE_DISABLED
		world.add_child(instance)
		await process_frame
		var main_sprite := instance.get_node_or_null(
			"AnimatedSprite2D"
		) as AnimatedSprite2D
		var overlay := (
			main_sprite.get_node_or_null("EmissionOverlay") as AnimatedSprite2D
			if main_sprite != null
			else null
		)
		_expect(
			main_sprite != null and overlay != null,
			"池化动画弹体缺少主图或发光叠层：%s" % scene_path
		)
		if main_sprite == null or overlay == null:
			instance.queue_free()
			await process_frame
			continue
		var frame_count := main_sprite.sprite_frames.get_frame_count(&"fly")
		main_sprite.stop()
		overlay.stop()
		main_sprite.frame = maxi(frame_count - 1, 0)
		main_sprite.frame_progress = 0.8
		overlay.frame = 0
		overlay.frame_progress = 0.1
		instance.call("on_pool_released", 1)
		instance.call("on_pool_acquired", 2)
		_expect(
			main_sprite.animation == overlay.animation
			and main_sprite.frame == overlay.frame
			and is_equal_approx(
				main_sprite.frame_progress,
				overlay.frame_progress
			)
			and main_sprite.is_playing() == overlay.is_playing(),
			"池化复用后发光叠层必须与主动画从同一帧重启：%s" % scene_path
		)
		instance.queue_free()
		await process_frame


func _instantiate_scene(scene_path: String) -> Node:
	var packed_scene := load(scene_path) as PackedScene
	_expect(packed_scene != null, "无法加载场景：%s" % scene_path)
	if packed_scene == null:
		return null
	return packed_scene.instantiate()


func _packed_scene_has_node(scene_path: String, node_name: StringName) -> bool:
	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null:
		return false
	var state := packed_scene.get_state()
	for node_index in range(state.get_node_count()):
		if state.get_node_name(node_index) == node_name:
			return true
	return false


func _count_named_emission_overlays(node: Node) -> int:
	var count := 1 if String(node.name).contains("EmissionOverlay") else 0
	for child in node.get_children():
		count += _count_named_emission_overlays(child)
	return count


func _find_named_nodes(
	node: Node,
	target_name: StringName,
	results: Array[Node]
) -> void:
	if node.name == target_name:
		results.append(node)
	for child in node.get_children():
		_find_named_nodes(child, target_name, results)


func _verify_projectile_halo(halo: Node, scene_path: String) -> void:
	var canvas_item := halo as CanvasItem
	_expect(canvas_item != null, "弹体柔光必须是CanvasItem：%s" % scene_path)
	if canvas_item == null:
		return
	_expect(
		canvas_item.material is CanvasItemMaterial,
		"弹体柔光必须使用共享的低成本CanvasItemMaterial：%s" % scene_path
	)
	var halo_material := canvas_item.material as CanvasItemMaterial
	if halo_material != null:
		_expect(
			halo_material.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD,
			"弹体柔光必须使用加色混合：%s" % scene_path
		)
		_expect(
			halo_material.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED,
			"弹体柔光必须不受夜间CanvasModulate二次压暗：%s" % scene_path
		)
	_expect(
		canvas_item.show_behind_parent,
		"弹体柔光必须绘制在清晰弹体之后：%s" % scene_path
	)
	if halo is Sprite2D:
		var halo_sprite := halo as Sprite2D
		_expect(halo_sprite.texture != null, "径向弹体柔光缺少纹理：%s" % scene_path)
		_expect(
			halo_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
			"径向弹体柔光必须使用线性过滤形成柔和扩散：%s" % scene_path
		)
		_expect(
			halo_sprite.z_index < 0,
			"径向弹体柔光必须位于弹体亮核之后：%s" % scene_path
		)
	elif halo is Line2D:
		_expect(
			(halo as Line2D).width >= 1.5,
			"射线弹道柔光必须宽于亮核：%s" % scene_path
		)


func _count_point_lights(node: Node) -> int:
	var count := 1 if node is PointLight2D else 0
	for child in node.get_children():
		count += _count_point_lights(child)
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
