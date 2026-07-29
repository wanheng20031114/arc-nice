extends RefCounted
class_name CodexVisibilityState

enum {
	REVEALED,
	UNKNOWN,
	HIDDEN,
}

const ALL: Array[int] = [REVEALED, UNKNOWN, HIDDEN]


static func is_valid(state: int) -> bool:
	return state in ALL
