extends RefCounted
class_name CombatTypes

## Stable combat-domain values. Keep the damage type wire values explicit:
## multiplayer payloads and legacy EnemyConfig.DamageType use the same 0/1 ABI.
enum DamageType {
	PHYSICAL = 0,
	MAGIC = 1,
}

enum DamageFlag {
	PERIODIC = 1 << 0,
	RANGED = 1 << 1,
	BYPASS_INVULNERABILITY = 1 << 2,
	BYPASS_DODGE = 1 << 3,
	BYPASS_MITIGATION = 1 << 4,
	NO_HIT_INVINCIBILITY = 1 << 5,
	SUPPRESS_HIT_PARTICLES = 1 << 6,
}

enum RoundingMode {
	FLOOR,
	NEAREST,
	CEIL,
}

## Serialized as `combat_outcome` in protocol v20. Never renumber in place;
## additions require a new explicit value and a protocol compatibility review.
enum DamageRejectionReason {
	NONE = 0,
	INVALID_REQUEST = 1,
	INVALID_AMOUNT = 2,
	TARGET_DEAD = 3,
	TARGET_UNAVAILABLE = 4,
	NOT_AUTHORITY = 5,
	INVULNERABLE = 6,
	DODGED = 7,
	DUPLICATE_EVENT = 8,
	UNTRUSTED_SOURCE = 9,
}


static func normalize_damage_type(value: int) -> int:
	return DamageType.MAGIC if value == DamageType.MAGIC else DamageType.PHYSICAL


static func has_flag(flags: int, flag: int) -> bool:
	return (flags & flag) != 0
