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
	SUPPRESS_HIT_FLASH = 1 << 7,
}

## Compact wire/presentation flags emitted only after authoritative damage is
## accepted. Keep values explicit: multiplayer batches serialize one byte.
enum DamageFeedbackFlag {
	HIT_PARTICLES = 1 << 0,
	DIRECT_HIT_FLASH = 1 << 1,
}

enum RoundingMode {
	FLOOR,
	NEAREST,
	CEIL,
}

## Serialized as `combat_outcome` in protocol v21. Never renumber in place;
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

## 敌人终结原因会直接进入多人协议；已有值不可重排或复用。
enum EnemyTerminalReason {
	DEFEATED = 0,
	ESCAPED = 1,
	REMOVED = 2,
}


static func normalize_damage_type(value: int) -> int:
	return DamageType.MAGIC if value == DamageType.MAGIC else DamageType.PHYSICAL


static func has_flag(flags: int, flag: int) -> bool:
	return (flags & flag) != 0
