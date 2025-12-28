extends Node
class_name GameSession

## 游戏会话管理器 - 管理单次游戏的运行时数据
## 注意：不作为自动加载，由 GameMain 创建和管理

signal gold_changed(new_amount: int, change: int)
signal master_key_changed(new_amount: int, change: int)

var _gold_internal: int = 0
var gold: int = 0:
	get: return _gold_internal
	set(value):
		var old = _gold_internal
		var new_val = max(0, value)
		if new_val != old:
			_gold_internal = new_val
			gold_changed.emit(new_val, new_val - old)

var _master_key_internal: int = 0
var master_key: int = 0:
	get: return _master_key_internal
	set(value):
		var old = _master_key_internal
		var new_val = max(0, value)
		if new_val != old:
			_master_key_internal = new_val
			master_key_changed.emit(new_val, new_val - old)

var score: int = 0
var current_wave: int = 0
var revive_count: int = 0
var selected_class_id: String = ""
var selected_weapon_ids: Array = []
var player: CharacterBody2D = null

## Survival 二阶段：当前阶段（1=阶段1，2=阶段2）
var survival_stage: int = 1

## Multi模式相关字段
var current_mode_id: String = "survival"  # 当前游戏模式
var current_map_id: String = ""  # 当前地图ID

## 游戏计时器相关字段
var _timer_start_time: float = 0.0  # 计时器开始时的时间戳
var _timer_accumulated: float = 0.0  # 累计游戏时间（秒）
var _timer_running: bool = false  # 计时器是否正在运行
var _timer_paused: bool = false  # 计时器是否暂停中

func reset() -> void:
	gold = 0
	master_key = 0
	score = 0
	current_wave = 0
	revive_count = 0
	selected_class_id = ""
	selected_weapon_ids.clear()
	current_mode_id = "survival"  # 重置为默认模式
	current_map_id = ""
	survival_stage = 1
	# 重置计时器
	_timer_start_time = 0.0
	_timer_accumulated = 0.0
	_timer_running = false
	_timer_paused = false
	print("[GameSession] 会话数据已重置")

func add_gold(amount: int) -> void:
	gold += amount

func remove_gold(amount: int) -> bool:
	if gold >= amount:
		gold -= amount
		return true
	return false

func add_master_key(amount: int) -> void:
	master_key += amount

func remove_master_key(amount: int) -> bool:
	if master_key >= amount:
		master_key -= amount
		return true
	return false

func can_afford(cost: int) -> bool:
	return gold >= cost

## ==================== 游戏计时器 ====================

## 开始计时器
func start_timer() -> void:
	if _timer_running:
		return
	_timer_start_time = Time.get_unix_time_from_system()
	_timer_running = true
	print("[GameSession] 计时器已启动")

## 停止计时器
func stop_timer() -> void:
	if not _timer_running:
		return
	_timer_accumulated += Time.get_unix_time_from_system() - _timer_start_time
	_timer_running = false
	_timer_paused = false
	print("[GameSession] 计时器已停止，累计时间: %.2f 秒" % _timer_accumulated)

## 暂停计时器（进入商店/死亡/ESC界面时调用）
func pause_timer() -> void:
	if not _timer_running or _timer_paused:
		return
	# 累计当前时间段
	_timer_accumulated += Time.get_unix_time_from_system() - _timer_start_time
	_timer_paused = true
	print("[GameSession] 计时器已暂停，累计时间: %.2f 秒" % _timer_accumulated)

## 恢复计时器（离开商店/复活/关闭ESC界面时调用）
func resume_timer() -> void:
	if not _timer_running or not _timer_paused:
		return
	# 重新记录起始时间
	_timer_start_time = Time.get_unix_time_from_system()
	_timer_paused = false
	print("[GameSession] 计时器已恢复")

## 获取已用时间（秒）
func get_elapsed_time() -> float:
	if _timer_running and not _timer_paused:
		return _timer_accumulated + (Time.get_unix_time_from_system() - _timer_start_time)
	return _timer_accumulated

## 重置计时器
func reset_timer() -> void:
	_timer_start_time = 0.0
	_timer_accumulated = 0.0
	_timer_running = false
	_timer_paused = false
	print("[GameSession] 计时器已重置")
