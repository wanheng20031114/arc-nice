extends Area2D
class_name Pickup

signal consumed(pickup: Pickup, collector_peer_id: int, applied_immediately: bool)

const BLINK_ENABLED_SHADER_PARAMETR := &"blink_enabled"

enum Lifecycle {
	AVAILABLE,
	CONSUMED,
	EXPIRED,
}

@export var config : PickupConfig

@export_range(0.0,10.0,0.1,"or_greater") var blink_before_expire : float = 1.2

@onready var sprite: Sprite2D = $Sprite2D
@onready var lifetime_timer: Timer = $LifetimeTimer
@onready var blink_timer: Timer = $BlinkTimer


# Called when the node enters the scene tree for the first time.
# 道具消失前的闪烁状态标志位，一旦开启就保持到道具消失为止。
var is_expiring: bool = false
var lifecycle := Lifecycle.AVAILABLE


# 初始化显示图标、寿命计时与拾取检测。
func _ready() -> void:
	lifetime_timer.one_shot = true
	_apply_config_to_visual()
	# 初始状态关闭闪烁效果
	_set_blink_enabled(false)
	_start_lifecycle_timers()


# 分别启动权威生命周期与一次性闪烁阶段计时，避免存活期间逐帧轮询。
func _start_lifecycle_timers() -> void:
	if lifetime_timer.wait_time <= 0.0:
		return
	lifetime_timer.start()
	if blink_before_expire <= 0.0:
		return
	var seconds_before_blink := lifetime_timer.wait_time - blink_before_expire
	if seconds_before_blink <= 0.0:
		_enter_expiring_state()
		return
	blink_timer.start(seconds_before_blink)


func _on_blink_timer_timeout() -> void:
	_enter_expiring_state()


func _enter_expiring_state() -> void:
	if lifecycle != Lifecycle.AVAILABLE or is_expiring:
		return
	is_expiring = true
	_set_blink_enabled(true)
	
# 将配置应用到视觉表现上
func _apply_config_to_visual() -> void:
	if config == null:
		push_warning("Pickup config is missing.")
		return
		
	sprite.texture = config.icon_texture
	sprite.scale = config.icon_scale
	# 掉落物直接显示源素材颜色，避免 HDR 乘色受 glow 与渲染后端影响。
	sprite.self_modulate = Color.WHITE
	lifetime_timer.wait_time = config.world_lifetime
	

# 当物体进入道具区域时触发，用于处理玩家拾取
func _on_body_entered(body: Node2D) -> void:
	if lifecycle != Lifecycle.AVAILABLE or config == null:
		return
		
	var player := body as Player
	if player == null:
		return
	var net_manager := get_node_or_null("/root/NetManager")
	if net_manager != null and net_manager.is_client():
		return

	if player.apply_pickup(config):
		_commit_consumption(player.peer_id, true)
		return

	var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
	var stored := (
		run_state.try_add_item_for_peer(player.peer_id, config)
		if net_manager != null and net_manager.is_host() and player.peer_id > 0
		else run_state.try_add_item(config)
	)
	if stored:
		player.play_world_inventory_pickup_feedback(config)
		_commit_consumption(player.peer_id, false)


func _commit_consumption(collector_peer_id: int, applied_immediately: bool) -> void:
	# The authoritative mutation has already succeeded. Mark the pickup before
	# emitting its synchronous signal so neither another overlap nor re-entry from
	# a listener can apply the same world item twice during this physics frame.
	lifecycle = Lifecycle.CONSUMED
	lifetime_timer.stop()
	blink_timer.stop()
	set_deferred("monitoring", false)
	set_deferred("collision_mask", 0)
	consumed.emit(self, collector_peer_id, applied_immediately)
	queue_free()

# 生命周期定时器超时，销毁道具
func _on_lifetime_timer_timeout() -> void:
	if lifecycle != Lifecycle.AVAILABLE:
		return
	lifecycle = Lifecycle.EXPIRED
	lifetime_timer.stop()
	blink_timer.stop()
	set_deferred("monitoring", false)
	set_deferred("collision_mask", 0)
	queue_free()

# 设置道具的闪烁效果开关
func _set_blink_enabled(enabled:bool) -> void:
	var sprite_material := sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETR,enabled)
