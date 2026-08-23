extends Resource
class_name EnemySimulationPolicy

## Per-family policy for the staged authoritative enemy simulation migration.
## A null policy and the default resource values both preserve the legacy path.

enum Mode {
	LEGACY,
	COMPAT_60,
	LAYERED_AREA,
	LAYERED_CONTACT,
}

enum MotionMode {
	FULL_PHYSICAL,
	CERTIFIED_DIRECT,
}

const MODE_ARGUMENT_PREFIX := "--enemy-simulation-mode="
const DEFAULT_LAYERED_AREA_DECISION_INTERVAL_FRAMES := 2
const MODE_NAMES: PackedStringArray = [
	"LEGACY",
	"COMPAT_60",
	"LAYERED_AREA",
	"LAYERED_CONTACT",
]

@export var mode: Mode = Mode.LEGACY
@export_range(1, 60, 1, "or_greater") var decision_interval_frames := (
	DEFAULT_LAYERED_AREA_DECISION_INTERVAL_FRAMES
)
@export_range(1, 60, 1, "or_greater") var navigation_interval_frames := 6
@export var motion_mode: MotionMode = MotionMode.FULL_PHYSICAL
@export var allow_enemy_targets := false
@export var allow_shared_contact_authority := false


func get_safe_mode() -> Mode:
	return normalize_mode(mode)


func get_safe_decision_interval_frames() -> int:
	return maxi(decision_interval_frames, 1)


func get_safe_navigation_interval_frames() -> int:
	return maxi(navigation_interval_frames, 1)


static func normalize_mode(value: int) -> Mode:
	if value < Mode.LEGACY or value > Mode.LAYERED_CONTACT:
		return Mode.LEGACY
	return value


static func mode_to_name(value: int) -> String:
	var safe_mode := int(normalize_mode(value))
	return MODE_NAMES[safe_mode]


static func parse_mode_name(value: String, fallback: Mode = Mode.LEGACY) -> Mode:
	var normalized := value.strip_edges().to_upper()
	for index in range(MODE_NAMES.size()):
		if normalized == MODE_NAMES[index]:
			return index
	return normalize_mode(fallback)


static func resolve_mode_from_arguments(
	arguments: PackedStringArray,
	fallback: Mode = Mode.LEGACY
) -> Mode:
	for argument in arguments:
		if argument.begins_with(MODE_ARGUMENT_PREFIX):
			return parse_mode_name(
				argument.trim_prefix(MODE_ARGUMENT_PREFIX),
				fallback
			)
	return normalize_mode(fallback)
