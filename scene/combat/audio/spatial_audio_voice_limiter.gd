extends RefCounted
class_name SpatialAudioVoiceLimiter

const REJECTED_ACTIVE_COUNT := -1
const VOICE_PREEMPTED_CALLBACK_META := &"spatial_audio_voice_preempted_callback"
const _SCOPE_BOUNDARY_META := &"spatial_audio_voice_scope_boundary"
const _SCOPE_STATE_META := &"spatial_audio_voice_scope_state"
const _VOICE_SCOPE_MEMBERSHIPS_META := &"spatial_audio_voice_scope_memberships"


class VoiceScopeState:
	extends RefCounted

	var voices_by_group: Dictionary = {}
	var voice_caps_by_group: Dictionary = {}


## 为不继承 CombatRuntimeBase 的测试世界或独立战斗容器声明显式边界。
## 标记随 Node 生命周期销毁；生产战斗根无需调用，因为强类型本身就是边界。
static func register_audio_scope(audio_scope: Node) -> bool:
	if (
		audio_scope == null
		or not is_instance_valid(audio_scope)
		or not audio_scope.is_inside_tree()
	):
		return false
	audio_scope.set_meta(_SCOPE_BOUNDARY_META, true)
	return true


## 返回节点所属的最近战斗运行时。Tower 中嵌套的 Rogue 会先命中自己的
## CombatRuntimeBase，因此两个仍在同一 SceneTree 的世界不会共用声部预算。
static func resolve_audio_scope(
	audio_player: AudioStreamPlayer2D,
	explicit_scope: Node = null
) -> Node:
	if explicit_scope != null:
		return explicit_scope if is_instance_valid(explicit_scope) else null
	var cursor: Node = audio_player
	while cursor != null:
		if cursor.has_meta(_SCOPE_BOUNDARY_META) or cursor is CombatRuntimeBase:
			return cursor
		cursor = cursor.get_parent()
	return null


## 在一个明确的世界声部域中预留播放槽，并返回该域内的其他活动声部数。
## 域账本挂在 scope 节点本身，group 只保留调试可见标签，不再用于全树发现。
static func claim_voice(
	audio_player: AudioStreamPlayer2D,
	audio_scope: Node,
	audio_group: StringName,
	max_simultaneous_count: int
) -> int:
	if (
		audio_player == null
		or audio_scope == null
		or not is_instance_valid(audio_player)
		or not is_instance_valid(audio_scope)
		or max_simultaneous_count <= 0
		or not audio_player.is_inside_tree()
		or not audio_scope.is_inside_tree()
		or audio_player.get_tree() != audio_scope.get_tree()
		or audio_player.get_viewport() != audio_scope.get_viewport()
		or (
			audio_player != audio_scope
			and not audio_scope.is_ancestor_of(audio_player)
		)
	):
		return REJECTED_ACTIVE_COUNT
	# 显式传入的节点从首次 claim 起就是结构边界；后续迁移检查沿父链读取
	# 该标记，不依赖节点名或 SceneTree group。
	if not register_audio_scope(audio_scope):
		return REJECTED_ACTIVE_COUNT
	if resolve_audio_scope(audio_player) != audio_scope:
		return REJECTED_ACTIVE_COUNT

	var state := _get_scope_state(audio_scope, true)
	if state == null:
		return REJECTED_ACTIVE_COUNT

	var viewport := audio_player.get_viewport()
	var camera := viewport.get_camera_2d() if viewport != null else null
	var listener_position := (
		camera.get_screen_center_position()
		if camera != null
		else Vector2.ZERO
	)
	var requested_distance_squared := 0.0
	if camera != null:
		requested_distance_squared = audio_player.global_position.distance_squared_to(
			listener_position
		)
		var audible_distance := maxf(audio_player.max_distance, 0.0)
		if (
			audible_distance > 0.0
			and requested_distance_squared > audible_distance * audible_distance
		):
			return REJECTED_ACTIVE_COUNT

	var entries: Array = state.voices_by_group.get(audio_group, [])
	var retained_entries: Array = []
	var requester_registered := false
	var active_players: Array[AudioStreamPlayer2D] = []
	for entry_variant in entries:
		var entry := entry_variant as WeakRef
		var active_player := (
			entry.get_ref() as AudioStreamPlayer2D
			if entry != null
			else null
		)
		if active_player == null or not is_instance_valid(active_player):
			continue
		if _get_claimed_scope(active_player, audio_group) != audio_scope:
			continue
		if resolve_audio_scope(active_player) != audio_scope:
			_clear_membership(active_player, audio_scope, audio_group)
			continue
		if not active_player.is_inside_tree():
			_clear_membership(active_player, audio_scope, audio_group)
			continue
		if active_player == audio_player:
			if active_player.playing or active_player.stream_paused:
				retained_entries.append(entry)
				requester_registered = true
			else:
				_clear_membership(active_player, audio_scope, audio_group)
			continue
		# 暂停、跨 Viewport 的 playback 保留归属但不占当前预算，也绝不能
		# 成为抢占目标；恢复或迁回后，下一次仲裁会重新看到它。
		if active_player.stream_paused:
			retained_entries.append(entry)
			continue
		if not active_player.playing:
			_clear_membership(active_player, audio_scope, audio_group)
			continue
		retained_entries.append(entry)
		if active_player.get_viewport() != viewport:
			continue
		active_players.append(active_player)
	state.voices_by_group[audio_group] = retained_entries
	_reconcile_active_cap(
		active_players,
		audio_scope,
		audio_group,
		viewport,
		max_simultaneous_count
	)

	if active_players.size() >= max_simultaneous_count:
		if camera == null:
			return REJECTED_ACTIVE_COUNT
		active_players.sort_custom(
			func(left: AudioStreamPlayer2D, right: AudioStreamPlayer2D) -> bool:
				return (
					left.global_position.distance_squared_to(listener_position)
					> right.global_position.distance_squared_to(listener_position)
				)
		)
		var farthest_player := active_players[0]
		var farthest_distance_squared := (
			farthest_player.global_position.distance_squared_to(listener_position)
		)
		if requested_distance_squared >= farthest_distance_squared:
			return REJECTED_ACTIVE_COUNT
		active_players.pop_front()
		_preempt_voice(farthest_player, audio_scope, audio_group)

	# 只有完成可听性与容量仲裁后才迁移旧租约；拒绝路径必须原样保留
	# 同播放器先前的 group/scope 归属和仍在播放的声音。
	_detach_other_group_memberships(audio_player, audio_group)
	_detach_from_previous_scope(audio_player, audio_scope, audio_group)
	state.voice_caps_by_group[audio_group] = max_simultaneous_count
	if not requester_registered:
		var updated_entries: Array = state.voices_by_group.get(audio_group, [])
		updated_entries.append(weakref(audio_player))
		state.voices_by_group[audio_group] = updated_entries
	_set_membership(audio_player, audio_scope, audio_group)
	if not audio_player.is_in_group(audio_group):
		audio_player.add_to_group(audio_group)
	return active_players.size()


## 显式释放一个已预留声部；stop() 与节点池归还都必须走这里，因为
## AudioStreamPlayer2D.stop() 不会发出 finished。
static func release_voice(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName
) -> void:
	if audio_player == null or not is_instance_valid(audio_player):
		return
	var audio_scope := _get_claimed_scope(audio_player, audio_group)
	if audio_scope != null:
		_release_from_scope_state(audio_player, audio_scope, audio_group)
	_clear_membership(audio_player, audio_scope, audio_group)


static func get_active_voice_count(
	audio_scope: Node,
	audio_group: StringName
) -> int:
	if (
		audio_scope == null
		or not is_instance_valid(audio_scope)
		or not audio_scope.is_inside_tree()
	):
		return 0
	var state := _get_scope_state(audio_scope, false)
	if state == null:
		return 0
	var viewport := audio_scope.get_viewport()
	var entries: Array = state.voices_by_group.get(audio_group, [])
	var retained_entries: Array = []
	var active_players: Array[AudioStreamPlayer2D] = []
	for entry_variant in entries:
		var entry := entry_variant as WeakRef
		var audio_player := (
			entry.get_ref() as AudioStreamPlayer2D
			if entry != null
			else null
		)
		if audio_player == null or not is_instance_valid(audio_player):
			continue
		if _get_claimed_scope(audio_player, audio_group) != audio_scope:
			continue
		if resolve_audio_scope(audio_player) != audio_scope:
			_clear_membership(audio_player, audio_scope, audio_group)
			continue
		if not audio_player.is_inside_tree():
			_clear_membership(audio_player, audio_scope, audio_group)
			continue
		if audio_player.stream_paused:
			retained_entries.append(entry)
			continue
		if not audio_player.playing:
			_clear_membership(audio_player, audio_scope, audio_group)
			continue
		retained_entries.append(entry)
		if (
			audio_player.get_viewport() == viewport
		):
			active_players.append(audio_player)
	state.voices_by_group[audio_group] = retained_entries
	var configured_cap := int(state.voice_caps_by_group.get(audio_group, 0))
	if configured_cap > 0:
		_reconcile_active_cap(
			active_players,
			audio_scope,
			audio_group,
			viewport,
			configured_cap
		)
	return active_players.size()


static func get_claimed_scope(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName
) -> Node:
	return _get_claimed_scope(audio_player, audio_group)


static func _get_scope_state(
	audio_scope: Node,
	create_if_missing: bool
) -> VoiceScopeState:
	var state: VoiceScopeState = null
	if audio_scope.has_meta(_SCOPE_STATE_META):
		state = audio_scope.get_meta(_SCOPE_STATE_META) as VoiceScopeState
	if state == null and create_if_missing:
		state = VoiceScopeState.new()
		audio_scope.set_meta(_SCOPE_STATE_META, state)
	return state


static func _detach_from_previous_scope(
	audio_player: AudioStreamPlayer2D,
	audio_scope: Node,
	audio_group: StringName
) -> void:
	var previous_scope := _get_claimed_scope(audio_player, audio_group)
	if previous_scope == null or previous_scope == audio_scope:
		return
	# 运行时迁移只转移账本，不能停止仍由新世界接管的 playback。
	_release_from_scope_state(audio_player, previous_scope, audio_group)
	_clear_membership(audio_player, previous_scope, audio_group)


static func _detach_other_group_memberships(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName
) -> void:
	var memberships := audio_player.get_meta(
		_VOICE_SCOPE_MEMBERSHIPS_META,
		{}
	) as Dictionary
	# 一个物理播放器的 stop()/playing 状态不可按类别拆分，因此它只能持有
	# 一个逻辑 group；重分类只转移账本，不中断当前 playback。
	for previous_group_variant in memberships.keys():
		var previous_group := StringName(previous_group_variant)
		if previous_group == audio_group:
			continue
		var scope_ref := memberships.get(previous_group, null) as WeakRef
		var previous_scope := (
			scope_ref.get_ref() as Node
			if scope_ref != null
			else null
		)
		if previous_scope != null:
			_release_from_scope_state(
				audio_player,
				previous_scope,
				previous_group
			)
		_clear_membership(audio_player, previous_scope, previous_group)


static func _preempt_voice(
	audio_player: AudioStreamPlayer2D,
	audio_scope: Node,
	audio_group: StringName
) -> void:
	# stop() 不发 finished，抢占必须先原子移除精确 scope 的租约。
	audio_player.stop()
	_release_from_scope_state(audio_player, audio_scope, audio_group)
	_clear_membership(audio_player, audio_scope, audio_group)
	var preempted_callback: Variant = audio_player.get_meta(
		VOICE_PREEMPTED_CALLBACK_META,
		Callable()
	)
	if preempted_callback is Callable and (preempted_callback as Callable).is_valid():
		(preempted_callback as Callable).call()


static func _reconcile_active_cap(
	active_players: Array[AudioStreamPlayer2D],
	audio_scope: Node,
	audio_group: StringName,
	viewport: Viewport,
	voice_cap: int
) -> void:
	if voice_cap <= 0 or active_players.size() <= voice_cap:
		return
	var camera := viewport.get_camera_2d() if viewport != null else null
	if camera != null:
		var listener_position := camera.get_screen_center_position()
		active_players.sort_custom(
			func(left: AudioStreamPlayer2D, right: AudioStreamPlayer2D) -> bool:
				return (
					left.global_position.distance_squared_to(listener_position)
					> right.global_position.distance_squared_to(listener_position)
				)
		)
	# stream_paused 恢复没有原生信号；下一次 count/claim 观察到超额时立即
	# 收敛。镜头存在时淘汰最远声部，否则保留账本中先到的声部。
	while active_players.size() > voice_cap:
		var removed_player: AudioStreamPlayer2D = (
			active_players.pop_front()
			if camera != null
			else active_players.pop_back()
		)
		_preempt_voice(removed_player, audio_scope, audio_group)


static func _release_from_scope_state(
	audio_player: AudioStreamPlayer2D,
	audio_scope: Node,
	audio_group: StringName
) -> void:
	if audio_scope == null or not is_instance_valid(audio_scope):
		return
	var state := _get_scope_state(audio_scope, false)
	if state == null:
		return
	var retained_entries: Array = []
	for entry_variant in state.voices_by_group.get(audio_group, []):
		var entry := entry_variant as WeakRef
		var registered_player := (
			entry.get_ref() as AudioStreamPlayer2D
			if entry != null
			else null
		)
		if registered_player != null and registered_player != audio_player:
			retained_entries.append(entry)
	if retained_entries.is_empty():
		state.voices_by_group.erase(audio_group)
		state.voice_caps_by_group.erase(audio_group)
	else:
		state.voices_by_group[audio_group] = retained_entries


static func _get_claimed_scope(
	audio_player: AudioStreamPlayer2D,
	audio_group: StringName
) -> Node:
	if audio_player == null or not is_instance_valid(audio_player):
		return null
	var memberships := audio_player.get_meta(
		_VOICE_SCOPE_MEMBERSHIPS_META,
		{}
	) as Dictionary
	var scope_ref := memberships.get(audio_group, null) as WeakRef
	return scope_ref.get_ref() as Node if scope_ref != null else null


static func _set_membership(
	audio_player: AudioStreamPlayer2D,
	audio_scope: Node,
	audio_group: StringName
) -> void:
	var memberships := audio_player.get_meta(
		_VOICE_SCOPE_MEMBERSHIPS_META,
		{}
	) as Dictionary
	memberships[audio_group] = weakref(audio_scope)
	audio_player.set_meta(_VOICE_SCOPE_MEMBERSHIPS_META, memberships)


static func _clear_membership(
	audio_player: AudioStreamPlayer2D,
	audio_scope: Node,
	audio_group: StringName
) -> void:
	if audio_player == null or not is_instance_valid(audio_player):
		return
	var memberships := audio_player.get_meta(
		_VOICE_SCOPE_MEMBERSHIPS_META,
		{}
	) as Dictionary
	var current_ref := memberships.get(audio_group, null) as WeakRef
	var current_scope := current_ref.get_ref() as Node if current_ref != null else null
	if audio_scope != null and current_scope != audio_scope:
		return
	memberships.erase(audio_group)
	if memberships.is_empty():
		audio_player.remove_meta(_VOICE_SCOPE_MEMBERSHIPS_META)
	else:
		audio_player.set_meta(_VOICE_SCOPE_MEMBERSHIPS_META, memberships)
	if audio_player.is_in_group(audio_group):
		audio_player.remove_from_group(audio_group)
