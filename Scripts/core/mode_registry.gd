extends Node

## 游戏模式注册表 - 管理所有可用的游戏模式

var _modes: Dictionary = {}  # mode_id -> BaseGameMode实例
var current_mode: BaseGameMode = null

func _ready() -> void:
	_register_builtin_modes()
	print("[ModeRegistry] 模式注册表就绪，已注册 %d 个模式" % _modes.size())

## 注册内置模式
func _register_builtin_modes() -> void:
	register_mode(SurvivalMode.new())
	register_mode(MultiMode.new())
	register_mode(OnlineMode.new())

## 注册模式
func register_mode(mode: BaseGameMode) -> void:
	if mode.mode_id.is_empty():
		push_error("[ModeRegistry] 模式ID为空，无法注册")
		return
	
	if _modes.has(mode.mode_id):
		push_warning("[ModeRegistry] 模式已存在，覆盖: %s" % mode.mode_id)
	
	_modes[mode.mode_id] = mode
	print("[ModeRegistry] 注册模式: %s (%s)" % [mode.mode_name, mode.mode_id])

## 获取模式
func get_mode(mode_id: String) -> BaseGameMode:
	if not _modes.has(mode_id):
		push_error("[ModeRegistry] 模式不存在: %s" % mode_id)
		return null
	return _modes[mode_id]

## 设置当前模式
func set_current_mode(mode_id: String) -> bool:
	var mode = get_mode(mode_id)
	if not mode:
		return false
	
	current_mode = mode
	print("[ModeRegistry] 当前模式设置为: %s" % mode.mode_name)
	return true

## 获取所有模式
func get_all_modes() -> Array:
	var modes: Array = []
	for mode in _modes.values():
		modes.append(mode)
	return modes

## 获取所有模式信息
func get_all_mode_info() -> Array:
	var info_list: Array = []
	for mode in _modes.values():
		info_list.append(mode.get_mode_info())
	return info_list
