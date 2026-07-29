extends SceneTree

const AMBIENT_SCENE_PATH := "res://scene/vfx/tower_defense_ambient_vfx.tscn"
const TOWER_SCENE_PATH := "res://scene/game_tower_defense.tscn"
const NON_TOWER_ENTRY_SCENES := [
	"res://scene/game.tscn",
	"res://scene/main_menu.tscn",
	"res://scene/multiplayer/multiplayer_lobby.tscn",
]
const MINIMUM_WIND_LINE_ASPECT := 4.0
const MAXIMUM_WIND_LINE_AMOUNT := 8
const MAXIMUM_WIND_LINE_SPEED := 350.0
const MINIMUM_WIND_PARTICLE_LIFETIME := 2.2
const MINIMUM_WIND_TRAIL_LIFETIME := 0.6
const MINIMUM_WIND_TRAIL_SECTIONS := 4
const MINIMUM_WIND_TRAIL_SUBDIVISIONS := 2
const MAXIMUM_WIND_DIRECTION_SPREAD := 10.0
const MAXIMUM_WIND_VERTICAL_GRAVITY := 12.0
const MINIMUM_AMBIENT_MOTE_AMOUNT := 30
const MAXIMUM_AMBIENT_MOTE_AMOUNT := 32
const MINIMUM_AMBIENT_MOTE_LIFETIME := 2.0
const MINIMUM_SMOOTH_FIXED_FPS := 24
const MAXIMUM_AMBIENT_MOTE_SPEED := 15.0
const MINIMUM_AMBIENT_MOTE_SPREAD := 35.0
const MAXIMUM_AMBIENT_MOTE_SPREAD := 120.0
const MAXIMUM_TOTAL_GPU_PARTICLES := 36
const MAXIMUM_PARTICLE_FIXED_FPS := 30
const MAXIMUM_WIND_TRAIL_COMPLEXITY := 240

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_native_scene_contract()
	_test_tower_only_integration()
	await process_frame

	if failures.is_empty():
		print("TOWER_DEFENSE_AMBIENT_VFX_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_native_scene_contract() -> void:
	_expect(
		ResourceLoader.exists(AMBIENT_SCENE_PATH, "PackedScene"),
		"塔防环境特效必须保存为独立PackedScene。"
	)
	if not ResourceLoader.exists(AMBIENT_SCENE_PATH, "PackedScene"):
		return
	var packed_scene := load(AMBIENT_SCENE_PATH) as PackedScene
	_expect(packed_scene != null, "塔防环境特效场景必须能作为PackedScene加载。")
	if packed_scene == null:
		return

	var ambient_root := packed_scene.instantiate()
	_expect(ambient_root.name == &"TowerDefenseAmbientVfx", "环境特效根节点命名不符合场景契约。")
	_expect(ambient_root.get_script() == null, "环境特效应由原生节点和资源搭建，不应依赖根脚本动态创建。")
	root.add_child(ambient_root)
	await process_frame

	var screen_layers := _collect_nodes_of_type(ambient_root, &"CanvasLayer")
	var particle_nodes := _collect_nodes_of_type(ambient_root, &"GPUParticles2D")
	var breathing_shader_items := _collect_time_multiply_shader_items(ambient_root)
	_expect(_collect_nodes_of_type(ambient_root, &"CanvasModulate").is_empty(), "GPU明暗呼吸不能继续使用CanvasModulate。")
	_expect(_collect_nodes_of_type(ambient_root, &"AnimationPlayer").is_empty(), "环境场景不能使用AnimationPlayer逐帧驱动。")
	_expect(_collect_nodes_of_type(ambient_root, &"AnimationTree").is_empty(), "环境场景不能使用AnimationTree逐帧驱动。")
	_expect(_collect_nodes_of_type(ambient_root, &"Timer").is_empty(), "环境场景不能使用Timer执行周期CPU逻辑。")
	_expect(_collect_nodes_of_type(ambient_root, &"CPUParticles2D").is_empty(), "环境特效禁止使用CPUParticles2D。")
	_expect(screen_layers.size() >= 1, "环境特效必须使用静态CanvasLayer承载屏幕效果。")
	_expect(particle_nodes.size() == 2, "屏幕CanvasLayer下必须包含风线和氛围微粒两组GPUParticles2D。")
	_expect(breathing_shader_items.size() == 1, "环境明暗必须由唯一全屏CanvasItem ShaderMaterial在GPU中完成。")
	var total_particle_amount := 0
	for particle_node in particle_nodes:
		var particles := particle_node as GPUParticles2D
		total_particle_amount += particles.amount
		_expect(
			particles.fixed_fps <= MAXIMUM_PARTICLE_FIXED_FPS,
			"%s的fixed_fps不能超过环境粒子性能上限。" % particles.name
		)
	_expect(
		total_particle_amount <= MAXIMUM_TOTAL_GPU_PARTICLES,
		"两组环境GPUParticles2D的总amount不能超过轻量预算。"
	)

	var all_scene_nodes: Array[Node] = [ambient_root]
	all_scene_nodes.append_array(_collect_all_descendants(ambient_root))
	for scene_node in all_scene_nodes:
		_expect(
			scene_node.get_script() == null,
			"环境场景节点%s不能附加Script或执行逐帧CPU逻辑。" % scene_node.name
		)
		if scene_node != ambient_root:
			_expect(scene_node.owner == ambient_root, "%s必须原生保存在环境特效场景中。" % scene_node.name)
	var ambient_scene_text := FileAccess.get_file_as_string(AMBIENT_SCENE_PATH)
	_expect(not ambient_scene_text.contains("Tween"), "环境场景不能以Tween驱动循环效果。")

	if particle_nodes.size() == 2:
		var viewport_center := particle_nodes[0].get_parent() as Control
		_expect(
			viewport_center != null and particle_nodes[1].get_parent() == viewport_center,
			"两组屏幕粒子必须共用随视口居中的Control锚点。"
		)
		if viewport_center != null:
			_expect(
				is_equal_approx(viewport_center.anchor_left, 0.5)
				and is_equal_approx(viewport_center.anchor_top, 0.5)
				and is_equal_approx(viewport_center.anchor_right, 0.5)
				and is_equal_approx(viewport_center.anchor_bottom, 0.5),
				"屏幕粒子中心必须使用0.5锚点适配宽屏与16:10画布。"
			)
		var particle_layer := _nearest_canvas_layer(particle_nodes[0])
		_expect(
			particle_layer != null and _nearest_canvas_layer(particle_nodes[1]) == particle_layer,
			"风线与氛围微粒必须共用一个静态屏幕CanvasLayer。"
		)
		if particle_layer != null:
			_expect(
				particle_layer.layer == 1,
				"环境粒子必须位于世界之上、玩家名牌与HUD之下的CanvasLayer 1。"
			)
	if breathing_shader_items.size() == 1:
		_test_gpu_breathing_shader(breathing_shader_items[0])

	for particle_node in particle_nodes:
		var particles := particle_node as GPUParticles2D
		_expect(_has_canvas_layer_ancestor(particles), "%s必须由屏幕CanvasLayer承载。" % particles.name)
		_expect(particles.emitting and not particles.one_shot, "%s必须作为持续环境粒子发射。" % particles.name)
		_expect(
			particles.process_material is ParticleProcessMaterial,
			"%s必须使用原生ParticleProcessMaterial。" % particles.name
		)

	var wind_candidates: Array[GPUParticles2D] = []
	for particle_node in particle_nodes:
		var particles := particle_node as GPUParticles2D
		if _texture_aspect_ratio(particles.texture) >= MINIMUM_WIND_LINE_ASPECT:
			wind_candidates.append(particles)
	_expect(wind_candidates.size() == 1, "两组粒子中必须恰有一组使用明显细长的风线纹理。")

	if wind_candidates.size() == 1:
		_test_wind_particle_contract(wind_candidates[0])
		var ambient_motes: GPUParticles2D = null
		for particle_node in particle_nodes:
			var particles := particle_node as GPUParticles2D
			if particles != wind_candidates[0]:
				ambient_motes = particles
				break
		_expect(ambient_motes != null, "必须能从两组粒子中识别出独立平滑氛围微粒发射器。")
		if ambient_motes != null:
			_test_ambient_mote_contract(ambient_motes)

	ambient_root.queue_free()
	for _cleanup_frame in range(3):
		await process_frame


func _test_wind_particle_contract(particles: GPUParticles2D) -> void:
	var process_material := particles.process_material as ParticleProcessMaterial
	if process_material == null:
		return
	_test_wind_lifetime_fade_shader(particles)
	_expect(
		particles.amount > 0 and particles.amount <= MAXIMUM_WIND_LINE_AMOUNT,
		"风线必须保持少量，避免重新形成密集高速雨幕。"
	)
	_expect(
		particles.lifetime >= MINIMUM_WIND_PARTICLE_LIFETIME,
		"风线粒子必须有足够寿命形成舒缓而连续的轨迹。"
	)
	_expect(particles.trail_enabled, "风线必须使用GPUParticles2D原生trail形成连续线条。")
	_expect(
		particles.trail_lifetime >= MINIMUM_WIND_TRAIL_LIFETIME,
		"风线trail必须保留足够时间，不能退化成短促闪线。"
	)
	_expect(
		particles.trail_sections >= MINIMUM_WIND_TRAIL_SECTIONS
		and particles.trail_section_subdivisions >= MINIMUM_WIND_TRAIL_SUBDIVISIONS,
		"风线trail必须具有足够分段与细分以平滑显示轻微弯曲。"
	)
	_expect(
		particles.amount
		* particles.trail_sections
		* particles.trail_section_subdivisions
		<= MAXIMUM_WIND_TRAIL_COMPLEXITY,
		"风线数量与trail分段乘积不能超过轻量几何预算。"
	)
	_expect(particles.texture != null, "风线必须提供可审计的细长Texture2D，而非默认方块粒子。")
	var texture_long_edge := 0.0
	if particles.texture != null:
		var texture_size := particles.texture.get_size()
		var short_edge := minf(texture_size.x, texture_size.y)
		var long_edge := maxf(texture_size.x, texture_size.y)
		texture_long_edge = long_edge
		_expect(
			short_edge > 0.0 and long_edge / short_edge >= MINIMUM_WIND_LINE_ASPECT,
			"风线纹理长宽比必须明显细长。"
		)
	_expect(_has_partial_alpha(particles, process_material), "风线可见部分必须带透明度，不能是实色粗线。")
	_expect(not process_material.turbulence_enabled, "风线必须关闭turbulence，避免trail卷曲成圈。")
	_expect(process_material.direction.x >= 0.5, "风线主方向必须明显朝右。")
	_expect(
		process_material.spread <= MAXIMUM_WIND_DIRECTION_SPREAD,
		"风线必须保持窄spread，避免随机转向破坏持续弯曲。"
	)
	_expect(is_zero_approx(process_material.gravity.x), "风线gravity.x必须接近零，避免横向加速失控。")
	_expect(
		not is_zero_approx(process_material.gravity.y)
		and absf(process_material.gravity.y) <= MAXIMUM_WIND_VERTICAL_GRAVITY,
		"风线必须使用温和且非零的纵向gravity形成持续小偏向。"
	)

	var viewport_size := Vector2(root.size)
	var visibility_rect := particles.visibility_rect
	_expect(visibility_rect.has_point(Vector2.ZERO), "风线visibility_rect必须覆盖发射器原点。")
	_expect(
		visibility_rect.size.x >= viewport_size.x
		and visibility_rect.size.y >= viewport_size.y,
		"风线visibility_rect必须至少覆盖整个基础视口，避免屏幕边缘被裁掉。"
	)
	_expect(
		process_material.initial_velocity_max > 0.0
		and process_material.initial_velocity_max <= MAXIMUM_WIND_LINE_SPEED,
		"风线必须明显放慢，并保持在克制的速度上限内。"
	)
	var maximum_travel := process_material.initial_velocity_max * particles.lifetime
	_expect(
		texture_long_edge > 0.0 and maximum_travel >= texture_long_edge,
		"风线在完整生命周期内至少应移动自身纹理长度，避免近似静止。"
	)


func _test_wind_lifetime_fade_shader(particles: GPUParticles2D) -> void:
	var fade_material := particles.material as ShaderMaterial
	_expect(fade_material != null, "风线必须使用CanvasItem ShaderMaterial在GPU中完成生命周期淡出。")
	if fade_material == null or fade_material.shader == null:
		return
	var shader_code := fade_material.shader.code
	_expect(shader_code.contains("shader_type canvas_item"), "风线淡出必须使用CanvasItem shader。")
	var vertex_body := _shader_vertex_body(shader_code)
	_expect(not vertex_body.is_empty(), "风线生命周期淡出必须在vertex()阶段完成。")
	_expect(
		vertex_body.contains("INSTANCE_CUSTOM.y"),
		"风线vertex()必须读取INSTANCE_CUSTOM.y获取粒子生命周期进度。"
	)
	_expect(vertex_body.contains("smoothstep"), "风线vertex()必须使用smoothstep平滑淡出。")
	_expect(
		_without_whitespace(vertex_body).contains("COLOR.a"),
		"风线vertex()必须用生命周期淡出结果调制COLOR.a。"
	)


func _test_ambient_mote_contract(particles: GPUParticles2D) -> void:
	var process_material := particles.process_material as ParticleProcessMaterial
	if process_material == null:
		return
	_expect(
		particles.amount >= MINIMUM_AMBIENT_MOTE_AMOUNT
		and particles.amount <= MAXIMUM_AMBIENT_MOTE_AMOUNT,
		"氛围微粒必须至少比原24粒增加25%，同时保持轻量上限。"
	)
	_expect(
		particles.lifetime >= MINIMUM_AMBIENT_MOTE_LIFETIME,
		"平滑氛围微粒必须有足够寿命完成舒缓漂移。"
	)
	_expect(particles.interpolate, "平滑氛围微粒必须开启interpolate。")
	_expect(particles.fract_delta, "平滑氛围微粒必须开启fract_delta。")
	_expect(
		particles.fixed_fps >= MINIMUM_SMOOTH_FIXED_FPS,
		"氛围微粒必须使用正常粒子更新频率，不能保留低帧率跳动。"
	)
	_expect(
		process_material.initial_velocity_min >= 0.0
		and process_material.initial_velocity_max <= MAXIMUM_AMBIENT_MOTE_SPEED,
		"氛围微粒移动必须缓慢克制。"
	)
	_expect(
		process_material.initial_velocity_min < process_material.initial_velocity_max,
		"氛围微粒的初速度范围必须包含温和随机变化。"
	)
	_expect(
		process_material.lifetime_randomness > 0.0,
		"氛围微粒寿命必须带少量随机性，避免整齐同步消失。"
	)
	_expect(
		process_material.spread >= MINIMUM_AMBIENT_MOTE_SPREAD
		and process_material.spread <= MAXIMUM_AMBIENT_MOTE_SPREAD,
		"氛围微粒spread必须有温和随机性，同时保留明确漂移方向。"
	)
	_expect(
		process_material.scale_min < process_material.scale_max,
		"氛围微粒尺寸必须包含温和随机变化。"
	)


func _texture_aspect_ratio(texture: Texture2D) -> float:
	if texture == null:
		return 0.0
	var texture_size := texture.get_size()
	var short_edge := minf(texture_size.x, texture_size.y)
	if short_edge <= 0.0:
		return 0.0
	return maxf(texture_size.x, texture_size.y) / short_edge


func _test_gpu_breathing_shader(canvas_item: CanvasItem) -> void:
	var shader_material := canvas_item.material as ShaderMaterial
	_expect(shader_material != null, "全屏明暗呼吸CanvasItem必须使用ShaderMaterial。")
	if shader_material == null or shader_material.shader == null:
		return
	var shader_code := shader_material.shader.code
	_expect(shader_code.contains("shader_type canvas_item"), "明暗呼吸必须使用CanvasItem shader。")
	_expect(_shader_vertex_uses_time(shader_code), "明暗呼吸必须在vertex()中使用TIME完成GPU循环。")
	_expect(shader_code.contains("blend_mul"), "全屏明暗呼吸必须使用乘色混合而不是CPU CanvasModulate。")
	var compact_shader_code := _without_whitespace(shader_code)
	_expect(not compact_shader_code.contains("fragment()"), "明暗呼吸shader禁止fragment()逐像素计算。")
	_expect(not shader_code.contains("hint_screen_texture"), "明暗呼吸shader禁止请求屏幕纹理副本。")
	_expect(not shader_code.contains("SCREEN_TEXTURE"), "明暗呼吸shader禁止读取SCREEN_TEXTURE。")
	_expect(_has_canvas_layer_ancestor(canvas_item), "全屏明暗呼吸CanvasItem必须由静态CanvasLayer承载。")
	_expect(canvas_item is Control, "全屏明暗呼吸必须使用可随视口伸缩的Control CanvasItem。")
	if canvas_item is Control:
		var control := canvas_item as Control
		_expect(
			is_equal_approx(control.anchor_left, 0.0)
			and is_equal_approx(control.anchor_top, 0.0)
			and is_equal_approx(control.anchor_right, 1.0)
			and is_equal_approx(control.anchor_bottom, 1.0),
			"GPU乘色CanvasItem必须以全矩形锚点覆盖任意视口。"
		)


func _collect_time_multiply_shader_items(search_root: Node) -> Array[CanvasItem]:
	var matches: Array[CanvasItem] = []
	for descendant in _collect_all_descendants(search_root):
		if not descendant is CanvasItem:
			continue
		var canvas_item := descendant as CanvasItem
		var shader_material := canvas_item.material as ShaderMaterial
		if shader_material == null or shader_material.shader == null:
			continue
		var shader_code := shader_material.shader.code
		if shader_code.contains("TIME") and shader_code.contains("blend_mul"):
			matches.append(canvas_item)
	return matches


func _shader_vertex_uses_time(shader_code: String) -> bool:
	return _shader_vertex_body(shader_code).contains("TIME")


func _shader_vertex_body(shader_code: String) -> String:
	var vertex_index := shader_code.find("void vertex")
	if vertex_index < 0:
		return ""
	var body_start := shader_code.find("{", vertex_index)
	if body_start < 0:
		return ""
	var brace_depth := 0
	for index in range(body_start, shader_code.length()):
		var character := shader_code.substr(index, 1)
		if character == "{":
			brace_depth += 1
		elif character == "}":
			brace_depth -= 1
			if brace_depth == 0:
				return shader_code.substr(body_start + 1, index - body_start - 1)
	return ""


func _without_whitespace(value: String) -> String:
	return value.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")


func _has_partial_alpha(
	particles: GPUParticles2D,
	process_material: ParticleProcessMaterial
) -> bool:
	if particles.modulate.a < 0.999 or particles.self_modulate.a < 0.999:
		return true
	if process_material.color.a < 0.999:
		return true
	if particles.texture == null:
		return false
	var image := particles.texture.get_image()
	if image == null or image.is_empty():
		return false
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var alpha := image.get_pixel(x, y).a
			if alpha > 0.001 and alpha < 0.999:
				return true
	return false


func _collect_nodes_of_type(search_root: Node, native_class: StringName) -> Array[Node]:
	var matches: Array[Node] = []
	for child in search_root.get_children():
		if child.is_class(native_class):
			matches.append(child)
		matches.append_array(_collect_nodes_of_type(child, native_class))
	return matches


func _collect_all_descendants(search_root: Node) -> Array[Node]:
	var descendants: Array[Node] = []
	for child in search_root.get_children():
		descendants.append(child)
		descendants.append_array(_collect_all_descendants(child))
	return descendants


func _nearest_canvas_layer(node: Node) -> CanvasLayer:
	var ancestor := node.get_parent()
	while ancestor != null:
		if ancestor is CanvasLayer:
			return ancestor as CanvasLayer
		ancestor = ancestor.get_parent()
	return null


func _has_canvas_layer_ancestor(node: Node) -> bool:
	return _nearest_canvas_layer(node) != null


func _test_tower_only_integration() -> void:
	var tower_scene_text := FileAccess.get_file_as_string(TOWER_SCENE_PATH)
	_expect(
		tower_scene_text.contains(AMBIENT_SCENE_PATH),
		"塔防主场景必须原生实例化独立环境特效场景。"
	)
	var tower_scene := load(TOWER_SCENE_PATH) as PackedScene
	_expect(tower_scene != null, "接入环境特效后，塔防主场景仍必须能够作为PackedScene加载。")
	if tower_scene != null:
		var tower_root := tower_scene.instantiate()
		var ambient_instance := tower_root.get_node_or_null("TowerDefenseAmbientVfx")
		_expect(ambient_instance != null, "塔防主场景必须预置TowerDefenseAmbientVfx实例。")
		if ambient_instance != null:
			_expect(
				ambient_instance.scene_file_path == AMBIENT_SCENE_PATH,
				"塔防主场景必须实例化独立环境特效PackedScene，而不是复制节点。"
			)
		tower_root.free()
	for non_tower_scene_path in NON_TOWER_ENTRY_SCENES:
		var scene_text := FileAccess.get_file_as_string(non_tower_scene_path)
		_expect(
			not scene_text.contains(AMBIENT_SCENE_PATH),
			"塔防环境特效不能接入非塔防入口场景：%s" % non_tower_scene_path
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
