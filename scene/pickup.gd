extends Area2D
class_name Pickup

const BLINK_ENABLED_SHADER_PARAMETR := &"blink_enabled"

@export var config : PickupConfig

@export_range(0.0,10.0,0.1,"or_greater") var blink_before_expire : float = 1.2

@onready var sprite: Sprite2D = $Sprite2D
@onready var lifetime_timer: Timer = $LifetimeTimer


# Called when the node enters the scene tree for the first time.
# 道具消失前的闪烁状态标志位，一旦开启就保持到道具消失为止。
var is_expiring: bool = false


# 初始化显示图标、寿命计时与拾取检测。
func _ready() -> void:
	lifetime_timer.one_shot = true
	# 启动生命周期定时器
	if lifetime_timer.wait_time > 0.0:
		lifetime_timer.start()
	# 初始状态关闭闪烁效果
	_set_blink_enabled(false)
	_apply_config_to_visual()


# 道具临近消失时开启闪烁提示。
func _process(_delta: float) -> void:
	if is_expiring:
		return
	if lifetime_timer.is_stopped():
		return
	if lifetime_timer.time_left > blink_before_expire:
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
	

# 当物体进入道具区域时触发，用于处理玩家拾取
func _on_body_entered(body: Node2D) -> void:
	if config == null:
		return
		
	var player := body as Player
	if player == null:
		return

	if player.apply_pickup(config):
		queue_free()
		return

	if RunState.try_add_item(config):
		queue_free()

# 生命周期定时器超时，销毁道具
func _on_lifetime_timer_timeout() -> void:
	queue_free()

# 设置道具的闪烁效果开关
func _set_blink_enabled(enabled:bool) -> void:
	var sprite_material := sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETR,enabled)
