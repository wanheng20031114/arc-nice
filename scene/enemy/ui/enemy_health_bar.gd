extends ProgressBar
class_name EnemyHealthBar

@export_range(0.0, 16.0, 1.0) var head_gap: float = 3.0
## Authored move-animation alpha bounds in sprite-local coordinates. Empty uses
## atlas geometry, so newly inherited enemy scenes still work before tuning.
@export var sprite_content_rect := Rect2()
## Animations that move the body inside a padded atlas canvas (for example takeoff).
@export var track_frame_animations: Array[StringName] = []

var _sprite: AnimatedSprite2D
var _standing_bounds: Rect2


func configure(sprite: AnimatedSprite2D, move_animation: StringName) -> void:
	_sprite = sprite
	var frames := sprite.sprite_frames
	# The unconfigured base scene has no artwork yet.
	if frames == null or not frames.has_animation(move_animation):
		return
	if sprite_content_rect.has_area():
		_standing_bounds = sprite.transform * sprite_content_rect
	else:
		_standing_bounds = Rect2()
		for frame_index in frames.get_frame_count(move_animation):
			var bounds := _get_frame_bounds(frames.get_frame_texture(move_animation, frame_index))
			_standing_bounds = bounds if frame_index == 0 else _standing_bounds.merge(bounds)
	size = Vector2(roundf(clampf(_standing_bounds.size.x * 0.75, 16.0, 40.0)), 4.0)
	_update_position()
	if not track_frame_animations.is_empty():
		if not visibility_changed.is_connected(_sync_frame_tracking):
			visibility_changed.connect(_sync_frame_tracking)
		_sync_frame_tracking()


func set_health(current_health: int, maximum_health: int) -> void:
	max_value = maxi(maximum_health, 1)
	value = clampi(current_health, 0, int(max_value))
	visible = current_health > 0 and current_health < maximum_health


func _get_frame_bounds(texture: Texture2D) -> Rect2:
	var frame_size := texture.get_size()
	var bounds := Rect2(Vector2.ZERO, frame_size)
	if texture is AtlasTexture:
		# Atlas margins are alignment padding, not part of the enemy's body.
		bounds.position = texture.margin.position
		bounds.size -= texture.margin.size
	bounds.position += _sprite.offset
	if _sprite.centered:
		bounds.position -= frame_size * 0.5
	if _sprite.flip_v:
		bounds.position.y = -bounds.end.y
	return _sprite.transform * bounds


func _update_position() -> void:
	var body_top := _standing_bounds.position.y
	if _sprite.animation in track_frame_animations:
		body_top = _get_frame_bounds(
			_sprite.sprite_frames.get_frame_texture(_sprite.animation, _sprite.frame)
		).position.y
	# Root-centered placement stays stable when offset sprites turn left/right.
	position = Vector2(-floorf(size.x * 0.5), floorf(body_top - head_gap - size.y))


func _sync_frame_tracking() -> void:
	if is_visible_in_tree():
		if not _sprite.frame_changed.is_connected(_update_position):
			_sprite.frame_changed.connect(_update_position)
			_sprite.animation_changed.connect(_update_position)
		_update_position()
	elif _sprite.frame_changed.is_connected(_update_position):
		_sprite.frame_changed.disconnect(_update_position)
		_sprite.animation_changed.disconnect(_update_position)
