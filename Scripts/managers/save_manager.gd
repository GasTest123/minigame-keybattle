extends Node

## 存档管理器
## 负责保存和读取用户数据（名字、楼层等）

const SAVE_FILE_PATH = "user://user_save.dat"
var save_file_path: String = ""

## ==================== 性能设置缓存（避免频繁字典查找） ====================
## 这些变量在加载存档或设置变更时同步更新，供高频调用直接访问
var shake_enabled_cache: bool = true
var trail_enabled_cache: bool = true

## 主音量缓存（0.0 - 1.0）
var master_volume_cache: float = 1.0

## 用户数据字典
var user_data: Dictionary = {
	"player_name": "",
	"floor_id": -1,  # -1 表示未选择，1-38 对应真实楼层，99 表示"不在漕河泾"
	"floor_name": "",
	"total_death_count": 0,  # 累计死亡次数
	"best_waves": {  # 各模式最高波次记录
		"survival": 0,
		"multi": 0
	},
	"display_mode": "fullscreen",  # 显示模式: "fullscreen" 或 "windowed"
	"floor_version": 0,  # 楼层版本，用于迁移逻辑控制（0: 旧版, 1: 迁移中, 2: 新版）
	"tutorial_shown": false,  # 是否已显示过教程（不再提示）
	"shake_enabled": true,  # 震屏效果开关（怪物死亡时）
	"trail_enabled": true,  # 子弹拖尾效果开关
	"master_volume": 1.0    # 主音量（线性 0.0-1.0）
}

func get_run_instance_id() -> String:
	var args := OS.get_cmdline_args()
	for i in args.size():
		var arg := args[i]
		if arg == "-i" or arg == "--instance-id":
			if i + 1 < args.size():
				return args[i + 1]
	return "1"

## 初始化
func _ready() -> void:
	resolve_save_file_path()
	load_user_data()
	# 应用保存的显示模式设置
	apply_display_mode()
	# 应用保存的主音量
	apply_master_volume()
	print("[SaveManager] 存档管理器初始化完成")

## 解析存档文件路径
func resolve_save_file_path() -> void:
	save_file_path = SAVE_FILE_PATH
	var instance_id := get_run_instance_id()
	if instance_id != "" and instance_id != "1":
		save_file_path = "user://user_save_%s.dat" % instance_id
	print("[SaveManager] 当前存档文件路径: %s" % save_file_path)

## 保存用户数据
func save_user_data() -> void:
	var file = FileAccess.open(save_file_path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] 无法打开存档文件进行写入: %s" % save_file_path)
		return
	
	# 将数据转换为JSON格式保存
	var json_string = JSON.stringify(user_data)
	file.store_string(json_string)
	file.close()
	
	print("[SaveManager] 用户数据已保存: %s" % user_data)

## 读取用户数据
func load_user_data() -> bool:
	if not FileAccess.file_exists(save_file_path):
		print("[SaveManager] 存档文件不存在，使用默认数据")
		return false
	
	var file = FileAccess.open(save_file_path, FileAccess.READ)
	if file == null:
		push_error("[SaveManager] 无法打开存档文件进行读取: %s" % save_file_path)
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	# 解析JSON数据
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	if parse_result != OK:
		push_error("[SaveManager] 解析存档文件失败: %s" % json.get_error_message())
		return false
	
	var loaded_data = json.data
	if loaded_data is Dictionary:
		user_data = loaded_data
		# 确保旧存档也有 total_death_count 字段
		if not user_data.has("total_death_count"):
			user_data["total_death_count"] = 0
		# 确保旧存档也有 best_waves 字段，并确保值为整数
		if not user_data.has("best_waves"):
			user_data["best_waves"] = {"survival": 0, "multi": 0}
		else:
			# JSON 加载可能将整数解析为浮点数，强制转换为整数
			var best_waves = user_data["best_waves"]
			for mode_id in best_waves.keys():
				best_waves[mode_id] = int(best_waves[mode_id])
		# 确保旧存档也有 display_mode 字段
		if not user_data.has("display_mode"):
			user_data["display_mode"] = "fullscreen"
		
		# 确保旧存档也有 floor_version 字段
		if not user_data.has("floor_version"):
			user_data["floor_version"] = 0
		
		# 确保旧存档也有 tutorial_shown 字段
		if not user_data.has("tutorial_shown"):
			user_data["tutorial_shown"] = false
		
		# 确保旧存档也有 shake_enabled 字段
		if not user_data.has("shake_enabled"):
			user_data["shake_enabled"] = true
		
		# 确保旧存档也有 trail_enabled 字段
		if not user_data.has("trail_enabled"):
			user_data["trail_enabled"] = true

		# 确保旧存档也有 master_volume 字段
		if not user_data.has("master_volume"):
			user_data["master_volume"] = 1.0
		else:
			# JSON 加载可能将数字解析为浮点，顺便做个夹取
			user_data["master_volume"] = clamp(float(user_data["master_volume"]), 0.0, 1.0)
			
		# 迁移旧版 floor_id（0-38 索引制）到新版（1-38 真实楼层号）
		_migrate_legacy_floor_id()
		# 同步性能设置缓存
		_sync_performance_cache()
		# 同步主音量缓存
		_sync_master_volume_cache()
		print("[SaveManager] 用户数据已加载: %s" % user_data)
		return true
	else:
		push_error("[SaveManager] 存档文件格式错误")
		return false

## 设置玩家名字
func set_player_name(p_name: String) -> void:
	user_data["player_name"] = p_name
	save_user_data()

## 设置楼层信息
func set_floor(floor_id: int, floor_name: String) -> void:
	user_data["floor_id"] = floor_id
	user_data["floor_name"] = floor_name
	user_data["floor_version"] = 2  # 设置为新版
	save_user_data()

## 获取玩家名字
func get_player_name() -> String:
	return user_data.get("player_name", "")

## 获取楼层ID
func get_floor_id() -> int:
	return user_data.get("floor_id", -1)

## 获取楼层名称
func get_floor_name() -> String:
	return user_data.get("floor_name", "")

## 检查是否有存档
func has_save_data() -> bool:
	return user_data.get("player_name", "") != "" and user_data.get("floor_id", -1) >= 0

## 清除存档数据
func clear_save_data() -> void:
	user_data = {
		"player_name": "",
		"floor_id": -1,
		"floor_name": "",
		"total_death_count": 0,
		"best_waves": {"survival": 0, "multi": 0},
		"display_mode": "fullscreen",
		"tutorial_shown": false
	}
	if FileAccess.file_exists(save_file_path):
		DirAccess.remove_absolute(save_file_path)
	print("[SaveManager] 存档数据已清除")

## 增加死亡次数
func increment_death_count() -> void:
	var current_count = user_data.get("total_death_count", 0)
	user_data["total_death_count"] = current_count + 1
	save_user_data()
	print("[SaveManager] 死亡次数已增加，当前总死亡次数:", user_data["total_death_count"])

## 获取总死亡次数
func get_total_death_count() -> int:
	return user_data.get("total_death_count", 0)

## ==================== 最高波次记录 ====================

## 获取指定模式的最高波次
func get_best_wave(mode_id: String) -> int:
	var best_waves = user_data.get("best_waves", {})
	return int(best_waves.get(mode_id, 0))

## 尝试更新指定模式的最高波次（如果新波次更高则更新）
## 返回 true 表示创建了新纪录
func try_update_best_wave(mode_id: String, wave: int) -> bool:
	var best_waves = user_data.get("best_waves", {"survival": 0, "multi": 0})
	var current_best = int(best_waves.get(mode_id, 0))
	
	if wave > current_best:
		best_waves[mode_id] = int(wave)  # 确保存储为整数
		user_data["best_waves"] = best_waves
		save_user_data()
		print("[SaveManager] %s 模式最高波次更新: %d -> %d" % [mode_id, current_best, wave])
		return true
	
	return false

## 迁移旧版 floor_id 到新版
## 旧版: 0-37 对应 1-38 楼，38 对应"不在漕河泾"
## 新版: 1-38 对应真实楼层，99 对应"不在漕河泾"
func _migrate_legacy_floor_id() -> void:
	var floor_id = user_data.get("floor_id", -1)
	var floor_name = user_data.get("floor_name", "")
	var changed = false
	
	# --- 自愈逻辑 1: 修复可能被之前的 bug 误改到 99 的 38 楼玩家 ---
	# 即使已经是新版标记，如果发现这种不一致也进行修复
	if floor_id == 99 and (floor_name == "38 楼" or floor_name == "38F"):
		user_data["floor_id"] = 38
		print("[SaveManager] 自愈：检测到 38 楼文本但 ID 为 99，已修正 ID 为 38")
		changed = true
	
	# 如果已经是新版且没有发生自愈修复，则跳过后续旧版迁移逻辑
	if not changed and user_data.get("floor_version", 0) >= 2:
		return
		
	# --- 旧版迁移逻辑 ---
	
	# 1. floor_id 为 0，肯定是旧版（旧版 0 = 1楼，新版没有0）
	if floor_id == 0:
		user_data["floor_id"] = 1
		if floor_name == "": user_data["floor_name"] = "1 楼"
		print("[SaveManager] 迁移：旧版 ID 0 -> 1")
		changed = true
		
	# 2. floor_id 为 38，需要根据 floor_name 区分
	elif floor_id == 38:
		# 如果名字不是 "38 楼" 且不是 "38F"，说明是旧版的 "不在漕河泾" (38 -> 99)
		if floor_name != "38 楼" and floor_name != "38F":
			user_data["floor_id"] = 99
			if floor_name == "" or floor_name == "不在漕河泾": 
				user_data["floor_name"] = "其他"
			print("[SaveManager] 迁移：旧版 ID 38 -> 99 (其他)")
			changed = true
		else:
			# 确认为新版 38 楼，虽然 ID 对了，但可能还没打版本号
			pass
			
	# 如果有改动，或者版本号不对，统一标记为新版并保存
	if changed or user_data.get("floor_version", 0) < 2:
		user_data["floor_version"] = 2
		save_user_data()
		print("[SaveManager] 存档已升级到最新楼层逻辑版本")

## ==================== 教程显示设置 ====================

## 设置教程是否已显示（不再提示）
func set_tutorial_shown(shown: bool) -> void:
	user_data["tutorial_shown"] = shown
	save_user_data()
	print("[SaveManager] 教程显示设置已保存: %s" % shown)

## 获取教程是否已显示（不再提示）
func get_tutorial_shown() -> bool:
	return user_data.get("tutorial_shown", false)

## 检查是否需要显示教程
func should_show_tutorial() -> bool:
	return not get_tutorial_shown()

## ==================== 显示模式设置 ====================

## 设置显示模式
## mode: "fullscreen" 或 "windowed"
func set_display_mode(mode: String) -> void:
	user_data["display_mode"] = mode
	save_user_data()
	print("[SaveManager] 显示模式已保存: %s" % mode)

## 获取显示模式
func get_display_mode() -> String:
	return user_data.get("display_mode", "fullscreen")

## 应用保存的显示模式
func apply_display_mode() -> void:
	var mode = get_display_mode()
	if mode == "windowed":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_set_windowed_size()
		print("[SaveManager] 应用显示模式: 窗口")
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		print("[SaveManager] 应用显示模式: 全屏")

## 根据屏幕分辨率设置窗口大小
func _set_windowed_size() -> void:
	var screen_size = DisplayServer.screen_get_size()
	var window_size: Vector2i
	
	# 根据屏幕分辨率选择窗口大小
	if screen_size.x > 1920 or screen_size.y > 1080:
		# 大于 1920x1080 的屏幕，窗口设为 1920x1080
		window_size = Vector2i(1920, 1080)
	else:
		# 1920x1080 或更小的屏幕，窗口设为 1600x900
		window_size = Vector2i(1600, 900)
	
	DisplayServer.window_set_size(window_size)
	# 居中显示
	var window_pos = (screen_size - window_size) / 2
	DisplayServer.window_set_position(window_pos)
	print("[SaveManager] 窗口大小: %dx%d" % [window_size.x, window_size.y])

## ==================== 视频性能设置 ====================

## 同步性能设置缓存（加载存档时调用）
func _sync_performance_cache() -> void:
	shake_enabled_cache = user_data.get("shake_enabled", true)
	trail_enabled_cache = user_data.get("trail_enabled", true)

## 同步主音量缓存（加载存档时调用）
func _sync_master_volume_cache() -> void:
	master_volume_cache = float(user_data.get("master_volume", 1.0))
	if master_volume_cache < 0.0:
		master_volume_cache = 0.0
	elif master_volume_cache > 1.0:
		master_volume_cache = 1.0

## 设置主音量（线性 0.0-1.0）
func set_master_volume_linear(volume: float) -> void:
	if volume < 0.0:
		volume = 0.0
	elif volume > 1.0:
		volume = 1.0
	user_data["master_volume"] = volume
	master_volume_cache = volume
	save_user_data()
	apply_master_volume()
	print("[SaveManager] 主音量已保存: %s" % volume)

## 获取主音量（线性 0.0-1.0）
func get_master_volume_linear() -> float:
	return master_volume_cache

## 应用保存的主音量到 Master 总线
func apply_master_volume() -> void:
	var bus_idx: int
	bus_idx = AudioServer.get_bus_index("Master")
	if bus_idx < 0:
		return

	var v: float = master_volume_cache
	if v < 0.0:
		v = 0.0
	elif v > 1.0:
		v = 1.0
	var db: float = -80.0
	if v > 0.0001:
		db = float(linear_to_db(v))
	AudioServer.set_bus_volume_db(bus_idx, db)

## 设置震屏效果开关
func set_shake_enabled(enabled: bool) -> void:
	user_data["shake_enabled"] = enabled
	shake_enabled_cache = enabled  # 同步更新缓存
	save_user_data()
	print("[SaveManager] 震屏效果设置已保存: %s" % enabled)

## 获取震屏效果开关（使用缓存，高频调用优化）
func get_shake_enabled() -> bool:
	return shake_enabled_cache

## 设置子弹拖尾效果开关
func set_trail_enabled(enabled: bool) -> void:
	user_data["trail_enabled"] = enabled
	trail_enabled_cache = enabled  # 同步更新缓存
	save_user_data()
	print("[SaveManager] 子弹拖尾效果设置已保存: %s" % enabled)

## 获取子弹拖尾效果开关（使用缓存，高频调用优化）
func get_trail_enabled() -> bool:
	return trail_enabled_cache
