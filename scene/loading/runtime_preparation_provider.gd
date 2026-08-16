@abstract
extends Node2D
class_name RuntimePreparationProvider

## 加载遮罩只消费这个强类型终态；缺少能力或失败都不能被解释成“已就绪”。
enum PreparationState {
	PREPARING,
	READY,
	FAILED,
}


class RuntimePreparationSnapshot extends RefCounted:
	var generation: int
	var state: PreparationState
	var stage: String
	var completed: int
	var total: int
	var failure_reason: String


	func _init(
		configured_generation: int,
		configured_state: PreparationState,
		configured_stage: String,
		configured_completed: int,
		configured_total: int,
		configured_failure_reason: String
	) -> void:
		generation = configured_generation
		state = configured_state
		stage = configured_stage
		completed = configured_completed
		total = maxi(configured_total, 1)
		failure_reason = configured_failure_reason


signal runtime_preparation_progress_changed(stage: String, completed: int, total: int)
signal runtime_preparation_completed
signal runtime_preparation_failed(reason: String)
signal runtime_preparation_state_changed(snapshot: RuntimePreparationSnapshot)

var runtime_preparation_complete := false
var runtime_preparation_stage := "等待场景初始化"
var runtime_preparation_completed_steps := 0
var runtime_preparation_total_steps := 1
var runtime_preparation_failure_reason := ""
var _runtime_preparation_state := PreparationState.PREPARING
var _runtime_preparation_generation := 0


# 每次 begin 都签发新 generation；跨 await 的调用方必须捕获并原样提交这个令牌。
func begin_runtime_preparation(stage: String = "等待场景初始化", total: int = 1) -> int:
	var previous_state := _runtime_preparation_state
	_runtime_preparation_generation += 1
	_runtime_preparation_state = PreparationState.PREPARING
	runtime_preparation_complete = false
	runtime_preparation_failure_reason = ""
	runtime_preparation_stage = stage
	runtime_preparation_completed_steps = 0
	runtime_preparation_total_steps = maxi(total, 1)
	if previous_state == PreparationState.FAILED:
		process_mode = Node.PROCESS_MODE_INHERIT
	_emit_runtime_preparation_state()
	return _runtime_preparation_generation


func update_runtime_preparation_progress(
	generation: int,
	stage: String,
	completed: int,
	total: int
) -> void:
	if not is_runtime_preparation_generation_preparing(generation):
		return
	runtime_preparation_stage = stage
	runtime_preparation_total_steps = maxi(total, 1)
	runtime_preparation_completed_steps = clampi(
		completed,
		0,
		runtime_preparation_total_steps
	)
	runtime_preparation_progress_changed.emit(
		runtime_preparation_stage,
		runtime_preparation_completed_steps,
		runtime_preparation_total_steps
	)
	_emit_runtime_preparation_state()


func mark_runtime_preparation_complete(generation: int) -> void:
	# 每个 generation 的终态不可逆；旧预热线程也不能写入后续新周期。
	if not is_runtime_preparation_generation_preparing(generation):
		return
	_runtime_preparation_state = PreparationState.READY
	runtime_preparation_complete = true
	runtime_preparation_stage = "战场准备完成"
	runtime_preparation_completed_steps = 1
	runtime_preparation_total_steps = 1
	runtime_preparation_progress_changed.emit("战场准备完成", 1, 1)
	_emit_runtime_preparation_state()
	runtime_preparation_completed.emit()


func mark_runtime_preparation_failed(generation: int, reason: String) -> void:
	if not is_runtime_preparation_generation_preparing(generation):
		return
	var exact_reason := reason.strip_edges()
	if exact_reason.is_empty():
		exact_reason = "运行时准备失败，但未提供失败原因。"
	_runtime_preparation_state = PreparationState.FAILED
	runtime_preparation_complete = false
	runtime_preparation_failure_reason = exact_reason
	runtime_preparation_stage = "战场准备失败"
	runtime_preparation_completed_steps = 0
	runtime_preparation_total_steps = 1
	# 失败场景仍会短暂留在加载遮罩下供人类读取原因，先冻结整棵运行时子树。
	process_mode = Node.PROCESS_MODE_DISABLED
	runtime_preparation_progress_changed.emit("战场准备失败", 0, 1)
	_emit_runtime_preparation_state()
	runtime_preparation_failed.emit(exact_reason)


func get_runtime_preparation_snapshot() -> RuntimePreparationSnapshot:
	return RuntimePreparationSnapshot.new(
		_runtime_preparation_generation,
		_runtime_preparation_state,
		runtime_preparation_stage,
		runtime_preparation_completed_steps,
		runtime_preparation_total_steps,
		runtime_preparation_failure_reason
	)


func get_runtime_preparation_generation() -> int:
	return _runtime_preparation_generation


func is_runtime_preparation_generation_current(generation: int) -> bool:
	return generation > 0 and generation == _runtime_preparation_generation


func is_runtime_preparation_generation_preparing(generation: int) -> bool:
	return (
		is_runtime_preparation_generation_current(generation)
		and _runtime_preparation_state == PreparationState.PREPARING
	)


func get_runtime_preparation_state() -> PreparationState:
	return _runtime_preparation_state


func is_runtime_preparation_complete() -> bool:
	return _runtime_preparation_state == PreparationState.READY


func is_runtime_preparation_failed() -> bool:
	return _runtime_preparation_state == PreparationState.FAILED


## 兼容只读诊断；正式加载屏障必须使用强类型 Snapshot，而不是猜字典字段。
func get_runtime_preparation_progress() -> Dictionary:
	return {
		"generation": _runtime_preparation_generation,
		"state": _runtime_preparation_state,
		"stage": runtime_preparation_stage,
		"completed": runtime_preparation_completed_steps,
		"total": runtime_preparation_total_steps,
		"failure_reason": runtime_preparation_failure_reason,
	}


func _emit_runtime_preparation_state() -> void:
	runtime_preparation_state_changed.emit(get_runtime_preparation_snapshot())


@abstract
func activate_runtime() -> void
