extends SceneTree

const AMBIENT_SCENE_PATH := "res://scene/vfx/rogue_route_ambient_vfx.tscn"
const ROUTE_SCENE_PATH := "res://scene/test_arena/test_rogue_route_p3.tscn"
const EXPECTED_WORLD_SIZE := Vector2(1072.0, 576.0)
const MINIMUM_PARTICLE_AMOUNT := 20
const MAXIMUM_PARTICLE_AMOUNT := 30
const MAXIMUM_PARTICLE_SPEED := 12.0
const MAXIMUM_VISIBLE_ALPHA := 0.2
const MAXIMUM_CHANNEL_DIFFERENCE := 0.02

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_ambient_scene_contract()
	_test_route_integration()
	_finish()


func _test_ambient_scene_contract() -> void:
	var packed_scene := load(AMBIENT_SCENE_PATH) as PackedScene
	_expect(packed_scene != null, "肉鸽路线环境粒子必须是可加载的 PackedScene。")
	if packed_scene == null:
		return
	var ambient_root := packed_scene.instantiate() as Node2D
	_expect(ambient_root != null, "肉鸽路线环境粒子根节点必须是 Node2D。")
	if ambient_root == null:
		return
	_expect(ambient_root.name == &"RogueRouteAmbientVfx", "环境粒子根节点命名不符合约定。")
	_expect(ambient_root.get_script() == null, "常驻环境粒子必须由原生场景节点构成，不应依赖脚本。")
	_expect(
		ambient_root.position.is_equal_approx(EXPECTED_WORLD_SIZE * 0.5),
		"环境粒子发射器必须位于路线世界中心。"
	)
	_expect(ambient_root.z_index == -20, "环境粒子必须位于遗址背景与路线节点之间。")

	var gpu_particles := _collect_nodes_of_type(ambient_root, &"GPUParticles2D")
	_expect(gpu_particles.size() == 1, "肉鸽路线只应保留一组轻量 GPUParticles2D。")
	_expect(
		_collect_nodes_of_type(ambient_root, &"CPUParticles2D").is_empty(),
		"常驻环境粒子禁止使用 CPUParticles2D。"
	)
	_expect(_collect_nodes_of_type(ambient_root, &"Timer").is_empty(), "环境粒子不应依赖 Timer。")
	_expect(
		_collect_nodes_of_type(ambient_root, &"AnimationPlayer").is_empty(),
		"环境粒子不应依赖逐帧动画节点。"
	)
	for child in ambient_root.get_children():
		_expect(child.owner == ambient_root, "环境粒子子节点必须静态保存在 PackedScene 中。")
	if gpu_particles.size() == 1:
		_test_particle_contract(gpu_particles[0] as GPUParticles2D)
	ambient_root.free()


func _test_particle_contract(particles: GPUParticles2D) -> void:
	_expect(particles.emitting and not particles.one_shot, "灰尘粒子必须持续循环发射。")
	_expect(
		particles.amount >= MINIMUM_PARTICLE_AMOUNT
		and particles.amount <= MAXIMUM_PARTICLE_AMOUNT,
		"灰尘粒子数量必须在轻量且可见的预算内。"
	)
	_expect(particles.lifetime >= 4.0, "灰尘粒子必须使用舒缓的长生命周期。")
	_expect(
		particles.preprocess > 0.0 and particles.preprocess <= particles.lifetime,
		"灰尘粒子应预热至入场可见，同时避免超出单个生命周期的启动开销。"
	)
	_expect(
		particles.fixed_fps >= 24 and particles.fixed_fps <= 30,
		"灰尘粒子应保持平滑且受控的 GPU 更新频率。"
	)
	_expect(particles.fract_delta and particles.interpolate, "灰尘粒子必须启用平滑插值。")
	_expect(
		particles.visibility_rect.size.x >= EXPECTED_WORLD_SIZE.x
		and particles.visibility_rect.size.y >= EXPECTED_WORLD_SIZE.y,
		"灰尘粒子的可见范围必须覆盖完整路线世界。"
	)
	_expect(particles.texture != null, "灰尘粒子必须绑定柔边纹理。")
	_expect(particles.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR, "柔边灰尘必须使用线性过滤。")

	var process_material := particles.process_material as ParticleProcessMaterial
	_expect(process_material != null, "灰尘粒子必须使用原生 ParticleProcessMaterial。")
	if process_material == null:
		return
	_expect(
		process_material.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_BOX,
		"灰尘粒子必须通过盒形区域覆盖地图。"
	)
	_expect(
		process_material.emission_box_extents.x >= EXPECTED_WORLD_SIZE.x * 0.5
		and process_material.emission_box_extents.y >= EXPECTED_WORLD_SIZE.y * 0.5,
		"灰尘发射范围必须覆盖路线世界边界。"
	)
	_expect(
		process_material.initial_velocity_min >= 0.0
		and process_material.initial_velocity_max <= MAXIMUM_PARTICLE_SPEED,
		"灰尘必须保持缓慢漂浮。"
	)
	_expect(_is_grayscale(process_material.color), "灰尘基础颜色必须为中性灰。")
	_test_lifetime_gradient(process_material.color_ramp)


func _test_lifetime_gradient(color_ramp: Texture2D) -> void:
	var ramp_texture := color_ramp as GradientTexture1D
	_expect(ramp_texture != null and ramp_texture.gradient != null, "灰尘必须使用生命周期透明渐变。")
	if ramp_texture == null or ramp_texture.gradient == null:
		return
	var maximum_alpha := 0.0
	for color in ramp_texture.gradient.colors:
		maximum_alpha = maxf(maximum_alpha, color.a)
		_expect(_is_grayscale(color), "灰尘生命周期渐变必须保持灰阶。")
	_expect(
		maximum_alpha > 0.0 and maximum_alpha <= MAXIMUM_VISIBLE_ALPHA,
		"灰尘透明度必须可见但不能遮挡路线信息。"
	)


func _test_route_integration() -> void:
	var route_scene_text := FileAccess.get_file_as_string(ROUTE_SCENE_PATH)
	_expect(route_scene_text.contains(AMBIENT_SCENE_PATH), "肉鸽主地图必须原生实例化环境粒子场景。")
	var route_scene := load(ROUTE_SCENE_PATH) as PackedScene
	_expect(route_scene != null, "接入环境粒子后肉鸽主地图仍必须可加载。")
	if route_scene == null:
		return
	var route_root := route_scene.instantiate()
	var world := route_root.get_node_or_null("World") as Node2D
	var backdrop := route_root.get_node_or_null("World/Backdrop") as Parallax2D
	var ambient := route_root.get_node_or_null("World/RogueRouteAmbientVfx") as Node2D
	var route_board := route_root.get_node_or_null("World/RouteBoard") as CanvasItem
	var players := route_root.get_node_or_null("World/Players") as CanvasItem
	_expect(world != null and ambient != null, "环境粒子必须作为 World 的静态子场景存在。")
	if ambient != null:
		_expect(ambient.get_parent() == world, "环境粒子必须随路线 World 一起显隐。")
		_expect(ambient.scene_file_path == AMBIENT_SCENE_PATH, "路线必须实例化正确的环境粒子资源。")
	_expect(
		backdrop != null
		and ambient != null
		and route_board != null
		and players != null
		and backdrop.z_index < ambient.z_index
		and ambient.z_index < route_board.z_index
		and route_board.z_index < players.z_index,
		"绘制顺序必须保持背景 < 灰尘 < 路线节点 < 玩家。"
	)
	route_root.free()


func _is_grayscale(color: Color) -> bool:
	return (
		absf(color.r - color.g) <= MAXIMUM_CHANNEL_DIFFERENCE
		and absf(color.g - color.b) <= MAXIMUM_CHANNEL_DIFFERENCE
	)


func _collect_nodes_of_type(search_root: Node, native_class: StringName) -> Array[Node]:
	var matches: Array[Node] = []
	for child in search_root.get_children():
		if child.is_class(native_class):
			matches.append(child)
		matches.append_array(_collect_nodes_of_type(child, native_class))
	return matches


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_AMBIENT_VFX_SMOKE_TEST_OK")
		quit(0)
		return
	print("ROGUE_ROUTE_AMBIENT_VFX_SMOKE_TEST_FAILED count=%d" % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
