@abstract
extends Resource
class_name GlobalResearchEffect

## 科研效果只描述不可变的玩法配置。运行时状态、计时与目标引用不得写回资源。


@abstract func is_valid() -> bool


## 同一科研内不允许出现两个相同语义键；不同科研可按各效果的既定规则组合。
@abstract func get_semantic_key() -> StringName
