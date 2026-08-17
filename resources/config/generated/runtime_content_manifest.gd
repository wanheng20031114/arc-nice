extends RefCounted
class_name RuntimeContentManifest

## 此文件由 dev_tools/generate_runtime_content_manifest.gd 生成，禁止手改。
## 运行时只信任这组编译期常量；JSON 清单用于代码审查与 --check 重现。
const SCHEMA_VERSION := 1
const CONTENT_SHA256 := "95a8ef590111fd5703d3b445c8bac98562b866d4b982d27f71d21f6a3652b7c6"
const ENEMY_ROOT_COUNT := 64
const PICKUP_ROOT_COUNT := 181
const CAMPAIGN_ROOT_COUNT := 26
const DEPENDENCY_COUNT := 1351


static func is_valid() -> bool:
	return (
		SCHEMA_VERSION == 1
		and ENEMY_ROOT_COUNT == 64
		and PICKUP_ROOT_COUNT == 181
		and CAMPAIGN_ROOT_COUNT == 26
		and DEPENDENCY_COUNT > 0
		and is_valid_wire_digest(CONTENT_SHA256)
	)


static func is_valid_wire_digest(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
			return false
	return true
