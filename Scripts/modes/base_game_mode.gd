extends Node
class_name BaseGameMode

## 游戏模式基类 - 定义所有游戏模式的通用接口

signal mode_started()
signal mode_ended()
signal wave_started(wave_number: int)
signal wave_ended(wave_number: int)

## 模式配置
var mode_id: String = ""
var mode_name: String = ""
var mode_description: String = ""
var total_waves: int = 20
var victory_condition_type: String = "waves"  # "waves", "keys", "time", "survival"
var wave_config_id: String = "default"  # 波次配置ID（对应JSON文件名）

## 胜利条件配置参数
var victory_waves: int = 20  # waves类型胜利条件：需要完成的波数
## 可选：二阶段胜利目标（仅部分模式使用，如 survival）
var victory2_waves: int = 0
var victory_keys: int = 200  # keys类型胜利条件：需要的钥匙数

## 获取“当前目标波数”（可被具体模式覆写，用于阶段/动态目标）
func get_victory_waves_target() -> int:
	return victory_waves

## 失败条件配置参数
var allow_revive: bool = true  # 是否允许复活（影响失败判定逻辑）

## 初始资源配置参数
var initial_gold: int = 0  # 游戏开始时初始获得的gold数量
var initial_master_key: int = 0  # 游戏开始时初始获得的masterkey数量

## 敌人刷新预警配置参数
var spawn_indicator_delay: float = 0.5  # 预警图片显示后多久刷新敌人（秒）

## 初始化模式
func initialize(config: Dictionary = {}) -> void:
	mode_id = config.get("mode_id", "")
	mode_name = config.get("mode_name", "未命名模式")
	mode_description = config.get("mode_description", "")
	total_waves = config.get("total_waves", 20)
	victory_condition_type = config.get("victory_condition", "waves")
	wave_config_id = config.get("wave_config_id", "default")
	victory_waves = config.get("victory_waves", 20)
	victory_keys = config.get("victory_keys", 200)
	allow_revive = config.get("allow_revive", true)
	initial_gold = config.get("initial_gold", 0)
	initial_master_key = config.get("initial_master_key", 0)
	spawn_indicator_delay = config.get("spawn_indicator_delay", 0.5)
	print("[BaseGameMode] 模式初始化: %s (%s)" % [mode_name, mode_id])

## 开始模式
func start_mode() -> void:
	print("[BaseGameMode] 模式开始: %s" % mode_name)
	mode_started.emit()

## 结束模式
func end_mode() -> void:
	print("[BaseGameMode] 模式结束: %s" % mode_name)
	mode_ended.emit()

## 检查胜利条件
func check_victory_condition() -> bool:
	match victory_condition_type:
		"waves":
			return _check_waves_victory()
		"keys":
			return _check_keys_victory()
		"time":
			return _check_time_victory()
		"survival":
			return false  # 生存模式没有胜利，只有失败
	return false

## 检查失败条件（统一实现，通过配置参数控制）
func check_defeat_condition() -> bool:
	var player = get_tree().get_first_node_in_group("player")
	if not player or not is_instance_valid(player):
		return false
	
	if "is_dead" in player and player.is_dead:
		# 如果允许复活，检查是否有足够金币复活
		if allow_revive:
			var revive_cost = GameConfig.revive_base_cost * (GameMain.revive_count + 1)
			if GameMain.gold < revive_cost:
				return true  # 死亡且无法复活，失败
		else:
			# 不允许复活，死亡即失败
			return true
	
	return false

## 获取当前波次配置（已废弃，由wave_system_v3从JSON加载）
func get_wave_config(wave_number: int) -> Dictionary:
	push_warning("[BaseGameMode] get_wave_config已废弃，请使用wave_config_id让wave_system_v3从JSON加载配置")
	return {}  # 不再使用硬编码配置

## 波次胜利检查（统一实现，通过配置参数控制）
func _check_waves_victory() -> bool:
	var wave_manager = Engine.get_main_loop().get_first_node_in_group("wave_manager")
	if not wave_manager or not "current_wave" in wave_manager:
		print("[BaseGameMode] 胜利检测: 未找到 wave_manager")
		return false
	
	# 已完成的波数 = current_wave（如果波次没在进行）或 current_wave - 1（如果在进行）
	var completed_waves = wave_manager.current_wave
	if "is_wave_in_progress" in wave_manager and wave_manager.is_wave_in_progress:
		completed_waves -= 1
	
	var target_waves := get_victory_waves_target()
	var result = completed_waves >= target_waves
	print("[BaseGameMode] 胜利检测: current_wave=%d, completed=%d, target=%d, result=%s" % 
		[wave_manager.current_wave, completed_waves, target_waves, result])
	return result

## 钥匙胜利检查（统一实现，通过配置参数控制）
func _check_keys_victory() -> bool:
	return GameMain.gold >= victory_keys

## 时间胜利检查（统一实现，通过配置参数控制）
func _check_time_victory() -> bool:
	return false  # 暂未实现

## 获取模式信息
func get_mode_info() -> Dictionary:
	return {
		"id": mode_id,
		"name": mode_name,
		"description": mode_description,
		"total_waves": total_waves,
		"victory_condition": victory_condition_type
	}

## 获取胜利条件描述文本（统一实现，通过配置参数控制）
func get_victory_description() -> String:
	match victory_condition_type:
		"keys":
			return "持有%d把钥匙" % victory_keys
		"waves":
			return "消灭%d波敌人" % get_victory_waves_target()
		"time":
			return "生存指定时间"
		"survival":
			return "尽可能生存"
	return "未知目标"

## 获取当前进度文本（格式：已完成数 / 目标数）
func get_progress_text() -> String:
	match victory_condition_type:
		"keys":
			return "%d / %d" % [GameMain.gold, victory_keys]
		"waves":
			var wave_manager = Engine.get_main_loop().get_first_node_in_group("wave_manager")
			var completed_waves = 0
			if wave_manager and "current_wave" in wave_manager:
				completed_waves = wave_manager.current_wave
				if "is_wave_in_progress" in wave_manager and wave_manager.is_wave_in_progress:
					completed_waves -= 1
			return "%d / %d" % [completed_waves, get_victory_waves_target()]
		"time":
			return "0 / ?"
		"survival":
			return ""
	return ""

## 获取完整的 KPI 文本
func get_kpi_text() -> String:
	var desc = get_victory_description()
	var progress = get_progress_text()
	
	if progress.is_empty():
		return "目标：%s" % desc
	else:
		return "目标：%s：%s" % [desc, progress]
