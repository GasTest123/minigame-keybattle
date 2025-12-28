extends Node

## 排行榜记录管理器
## 管理本地排行榜数据的存储和读取
## 数据使用 Base64 编码 + SHA-256 哈希校验，防止简单篡改

## 上传状态信号
## state: "uploading" | "success" | "failed"
signal upload_state_changed(mode_id: String, state: String)

const SAVE_FILE_PATH = "user://leaderboard.dat"
const HASH_SALT = "brotato_hxh_2025_leaderboard"  # 哈希盐值

## 排行榜记录
var records: Dictionary = {
	"survival": null,  # Survival模式最佳记录
	"multi": null      # Multi模式最佳记录
}

## 上传状态（记录哪些模式的数据尚未成功上传到服务器）
var _pending_upload: Dictionary = {
	"survival": false,
	"multi": false
}

## 是否正在上传中（防止重复上传）
var _uploading: Dictionary = {
	"survival": false,
	"multi": false
}

## 本局是否创建了新纪录（用于 UI 显示，在新局开始时重置）
var _session_new_record: Dictionary = {
	"survival": false,
	"multi": false
}

## 本局上传结果（用于 UI 显示，在新局开始时重置）
## "none" | "uploading" | "success" | "failed"
var _session_upload_result: Dictionary = {
	"survival": "none",
	"multi": "none"
}

## 计算记录指纹：用于判断上传期间是否产生了更新
func _record_fingerprint(data: Dictionary) -> String:
	return JSON.stringify(data)

func _ready() -> void:
	load_records()
	print("[LeaderboardManager] 排行榜管理器初始化完成")
	
	# 启动时尝试上传未成功的记录
	_retry_pending_uploads()

## ==================== 公共方法 ====================

## 尝试更新 Survival 模式记录（波次完成或胜利时调用）
## 新纪录判定逻辑：wave 优先，wave 相同时比较时间
## 返回 true 表示创建了新纪录
func try_update_survival_record(wave: int, completion_time: float, death_count: int) -> bool:
	var current = records.get("survival")
	
	# 如果没有记录，直接创建新纪录
	if current == null:
		records["survival"] = _create_survival_record(wave, completion_time, death_count)
		_pending_upload["survival"] = true
		_session_new_record["survival"] = true
		save_records()
		_upload_in_background("survival", 1, records["survival"])
		print("[LeaderboardManager] Survival模式新纪录! 波次: %d, 时间: %.2f秒" % [wave, completion_time])
		return true
	
	var current_wave = current.get("best_wave", 30)  # 兼容旧数据，默认30波
	var current_time = current.get("completion_time_seconds", INF)
	
	var is_new_record = false
	
	# 判定逻辑：
	# 1. wave > 存档 wave → 新纪录
	# 2. wave == 存档 wave 且 time < 存档 time → 新纪录
	# 3. wave < 存档 wave → 不是新纪录
	if wave > current_wave:
		is_new_record = true
		print("[LeaderboardManager] Survival模式新纪录! 波次突破: %d → %d" % [current_wave, wave])
	elif wave == current_wave and completion_time < current_time:
		is_new_record = true
		print("[LeaderboardManager] Survival模式新纪录! 同波次更快: %.2f秒 → %.2f秒" % [current_time, completion_time])
	
	if is_new_record:
		records["survival"] = _create_survival_record(wave, completion_time, death_count)
		_pending_upload["survival"] = true
		_session_new_record["survival"] = true
		save_records()
		_upload_in_background("survival", 1, records["survival"])
		return true
	
	print("[LeaderboardManager] Survival模式未打破纪录 (当前: 波次%d/%.2f秒, 最佳: 波次%d/%.2f秒)" % [wave, completion_time, current_wave, current_time])
	return false

## 尝试更新 Multi 模式记录（游戏结束时调用）
## 返回 true 表示创建了新纪录
func try_update_multi_record(best_wave: int, death_count: int) -> bool:
	var current = records.get("multi")
	
	# 如果没有记录，或者新波次更高，则更新
	if current == null or best_wave > current.get("best_wave", 0):
		records["multi"] = _create_multi_record(best_wave, death_count)
		_pending_upload["multi"] = true  # 标记需要上传
		_session_new_record["multi"] = true
		save_records()
		_upload_in_background("multi", 2, records["multi"])
		print("[LeaderboardManager] Multi模式新纪录! 波次: %d" % best_wave)
		return true
	
	print("[LeaderboardManager] Multi模式未打破纪录 (当前: %d波, 最佳: %d波)" % [best_wave, current.get("best_wave", 0)])
	return false

## 获取 Survival 模式记录
func get_survival_record() -> Dictionary:
	var record = records.get("survival")
	if record == null:
		return {}
	return record

## 获取 Multi 模式记录
func get_multi_record() -> Dictionary:
	var record = records.get("multi")
	if record == null:
		return {}
	return record

## 获取指定模式的上传状态
## 返回: "idle" | "uploading" | "pending"
func get_upload_state(mode_id: String) -> String:
	if _uploading.get(mode_id, false):
		return "uploading"
	if _pending_upload.get(mode_id, false):
		return "pending"
	return "idle"

## 检查指定模式是否正在上传
func is_uploading(mode_id: String) -> bool:
	return _uploading.get(mode_id, false)

## 检查指定模式是否有待上传的记录
func is_pending_upload(mode_id: String) -> bool:
	return _pending_upload.get(mode_id, false)

## 检查本局是否创建了新纪录
func has_new_record_this_session(mode_id: String) -> bool:
	return _session_new_record.get(mode_id, false)

## 重置本局新纪录标志（在新局开始时调用）
func reset_session_new_record() -> void:
	_session_new_record["survival"] = false
	_session_new_record["multi"] = false
	_session_upload_result["survival"] = "none"
	_session_upload_result["multi"] = "none"

## 获取本局上传结果
func get_session_upload_result(mode_id: String) -> String:
	return _session_upload_result.get(mode_id, "none")

## 清除所有记录
func clear_all_records() -> void:
	records = {
		"survival": null,
		"multi": null
	}
	_pending_upload = {
		"survival": false,
		"multi": false
	}
	if FileAccess.file_exists(SAVE_FILE_PATH):
		DirAccess.remove_absolute(SAVE_FILE_PATH)
	print("[LeaderboardManager] 所有记录已清除")

## ==================== 保存/加载 ====================

## 保存记录到文件（包含上传状态）
func save_records() -> void:
	var file = FileAccess.open(SAVE_FILE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[LeaderboardManager] 无法打开文件进行写入: %s" % SAVE_FILE_PATH)
		return
	
	# 将记录和上传状态一起保存
	var save_content = {
		"records": records,
		"pending_upload": _pending_upload
	}
	var json_string = JSON.stringify(save_content)
	
	# Base64 编码
	var encoded_data = _encode_data(json_string)
	
	# 生成哈希签名
	var signature = _generate_signature(encoded_data)
	
	# 保存格式: {"data": "<base64>", "sig": "<hash>"}
	var save_data = {
		"data": encoded_data,
		"sig": signature
	}
	
	file.store_string(JSON.stringify(save_data))
	file.close()
	
	print("[LeaderboardManager] 记录已保存")

## 从文件加载记录
func load_records() -> bool:
	if not FileAccess.file_exists(SAVE_FILE_PATH):
		print("[LeaderboardManager] 排行榜文件不存在，使用默认数据")
		return false
	
	var file = FileAccess.open(SAVE_FILE_PATH, FileAccess.READ)
	if file == null:
		push_error("[LeaderboardManager] 无法打开文件进行读取: %s" % SAVE_FILE_PATH)
		return false
	
	var file_content = file.get_as_text()
	file.close()
	
	# 解析外层JSON
	var json = JSON.new()
	var parse_result = json.parse(file_content)
	if parse_result != OK:
		push_warning("[LeaderboardManager] 文件格式错误，清除记录")
		_clear_corrupted_data()
		return false
	
	var save_data = json.data
	if not save_data is Dictionary:
		push_warning("[LeaderboardManager] 数据格式错误，清除记录")
		_clear_corrupted_data()
		return false
	
	var encoded_data = save_data.get("data", "")
	var signature = save_data.get("sig", "")
	
	# 验证签名
	if not _verify_signature(encoded_data, signature):
		push_warning("[LeaderboardManager] 签名验证失败，数据可能被篡改，清除记录")
		_clear_corrupted_data()
		return false
	
	# Base64 解码
	var json_string = _decode_data(encoded_data)
	if json_string.is_empty():
		push_warning("[LeaderboardManager] 解码失败，清除记录")
		_clear_corrupted_data()
		return false
	
	# 解析记录数据
	parse_result = json.parse(json_string)
	if parse_result != OK:
		push_warning("[LeaderboardManager] 记录数据解析失败，清除记录")
		_clear_corrupted_data()
		return false
	
	var loaded_data = json.data
	if loaded_data is Dictionary:
		# 新格式：包含 records 和 pending_upload
		if loaded_data.has("records"):
			records = loaded_data["records"]
			if loaded_data.has("pending_upload"):
				_pending_upload = loaded_data["pending_upload"]
		else:
			# 旧格式兼容：直接就是 records
			records = loaded_data
		
		# 迁移旧版 Survival 记录（添加 best_wave 字段）
		_migrate_survival_record()
		
		print("[LeaderboardManager] 记录已加载 | 待上传: %s" % _pending_upload)
		return true
	
	push_warning("[LeaderboardManager] 记录数据格式错误，清除记录")
	_clear_corrupted_data()
	return false

# 从服务器加载记录
func load_leaderboard_data() -> Dictionary:
	var data = await ApiManager.load_leaderboard_data()
	if data is Dictionary and data.has("leaderboards"):
		# TODO: 根据客户端需求自行排序
		return data["leaderboards"]
	return {}

# 保存记录到服务器（内部方法）
func _do_upload(type: int, data: Dictionary) -> bool:
	var json_string = JSON.stringify(data)
	var result = await ApiManager.save_leaderboard_data(type, json_string)
	if result.has("error"):
		push_error("[LeaderboardManager] ✗ 上传失败: %s" % result["error"])
		return false
	elif result.has("success") and result["success"]:
		print("[LeaderboardManager] ✓ 上传成功！")
		return true
	else:
		push_warning("[LeaderboardManager] ⚠ 上传返回未知结果: %s" % result)
		return false

## 后台上传（不阻塞游戏流程，带保护机制）
func _upload_in_background(mode_id: String, type: int, data: Dictionary) -> void:
	# 防止重复上传
	if _uploading.get(mode_id, false):
		# 上传过程中产生了新纪录：标记 pending，等待本次上传结束后补传最新数据
		_pending_upload[mode_id] = true
		_session_upload_result[mode_id] = "pending"
		upload_state_changed.emit(mode_id, "pending")
		print("[LeaderboardManager] %s 模式正在上传中，标记pending等待补传" % mode_id)
		return
	
	var start_fp := _record_fingerprint(data)
	_uploading[mode_id] = true
	_session_upload_result[mode_id] = "uploading"
	
	# 发出上传中信号
	upload_state_changed.emit(mode_id, "uploading")
	
	# 执行上传
	var success = await _do_upload(type, data)
	
	_uploading[mode_id] = false
	
	if success:
		# 如果上传期间记录发生变化：保持 pending 并立即补传最新记录，保证最终一致
		var current_record = records.get(mode_id)
		var current_fp := ""
		if current_record is Dictionary:
			current_fp = _record_fingerprint(current_record)
		
		if current_fp != start_fp:
			_pending_upload[mode_id] = true
			_session_upload_result[mode_id] = "pending"
			save_records()
			upload_state_changed.emit(mode_id, "pending")
			print("[LeaderboardManager] %s 模式上传成功但记录已更新，开始补传最新数据" % mode_id)
			# 延后一帧再触发，避免重入
			call_deferred("_upload_in_background", mode_id, type, current_record if (current_record is Dictionary) else data)
			return
		
		# 上传成功且无更新：清除待上传标记
		_pending_upload[mode_id] = false
		_session_upload_result[mode_id] = "success"
		save_records()  # 保存更新后的状态
		print("[LeaderboardManager] %s 模式上传完成，已清除待上传标记" % mode_id)
		# 发出上传成功信号
		upload_state_changed.emit(mode_id, "success")
	else:
		# 上传失败，保持待上传标记，下次启动时重试
		_session_upload_result[mode_id] = "failed"
		print("[LeaderboardManager] %s 模式上传失败，将在下次启动时重试" % mode_id)
		# 发出上传失败信号
		upload_state_changed.emit(mode_id, "failed")

## 启动时重试上传未成功的记录
func _retry_pending_uploads() -> void:
	# 等待一小段时间，确保网络和其他系统就绪
	await get_tree().create_timer(1.0).timeout
	
	print("[LeaderboardManager] 检查待上传记录...")
	
	# 重试 Survival 模式
	if _pending_upload.get("survival", false) and records.get("survival") != null:
		print("[LeaderboardManager] 重试上传 Survival 模式记录...")
		_upload_in_background("survival", 1, records["survival"])
	
	# 重试 Multi 模式
	if _pending_upload.get("multi", false) and records.get("multi") != null:
		print("[LeaderboardManager] 重试上传 Multi 模式记录...")
		_upload_in_background("multi", 2, records["multi"])

## 手动触发重新上传所有记录（可用于调试或用户主动同步）
func force_upload_all() -> void:
	print("[LeaderboardManager] 强制上传所有记录...")
	
	if records.get("survival") != null:
		_pending_upload["survival"] = true
		_upload_in_background("survival", 1, records["survival"])
	
	if records.get("multi") != null:
		_pending_upload["multi"] = true
		_upload_in_background("multi", 2, records["multi"])

## 手动触发上传指定模式的记录（用于 UI 中的上传按钮）
## mode_id: "survival" 或 "multi"
func manual_upload(mode_id: String) -> void:
	var record: Dictionary
	var type: int
	
	if mode_id == "survival":
		record = records.get("survival", {})
		type = 1
	elif mode_id == "multi":
		record = records.get("multi", {})
		type = 2
	else:
		push_error("[LeaderboardManager] 无效的模式ID: %s" % mode_id)
		return
	
	if record.is_empty():
		push_warning("[LeaderboardManager] 没有可上传的 %s 记录" % mode_id)
		return
	
	print("[LeaderboardManager] 手动上传 %s 模式记录..." % mode_id)
	_upload_in_background(mode_id, type, record)

## ==================== 私有方法 ====================

## 创建 Survival 模式记录
func _create_survival_record(wave: int, completion_time: float, death_count: int) -> Dictionary:
	return {
		"mode": "survival",
		"player_name": SaveManager.get_player_name(),
		"floor_id": SaveManager.get_floor_id(),
		"best_wave": wave,
		"completion_time_seconds": completion_time,
		"total_death_count": death_count,
		"completed_at": _get_iso_timestamp()
	}

## 创建 Multi 模式记录
func _create_multi_record(best_wave: int, death_count: int) -> Dictionary:
	return {
		"mode": "multi",
		"player_name": SaveManager.get_player_name(),
		"floor_id": SaveManager.get_floor_id(),
		"best_wave": best_wave,
		"total_death_count": death_count,
		"achieved_at": _get_iso_timestamp()
	}

## 获取 ISO 8601 格式时间戳
func _get_iso_timestamp() -> String:
	var datetime = Time.get_datetime_dict_from_system(true)  # UTC时间
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [
		datetime.year,
		datetime.month,
		datetime.day,
		datetime.hour,
		datetime.minute,
		datetime.second
	]

## Base64 编码
func _encode_data(data: String) -> String:
	return Marshalls.utf8_to_base64(data)

## Base64 解码
func _decode_data(encoded: String) -> String:
	return Marshalls.base64_to_utf8(encoded)

## 生成哈希签名
func _generate_signature(data: String) -> String:
	var combined = data + HASH_SALT
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(combined.to_utf8_buffer())
	var hash_bytes = ctx.finish()
	return hash_bytes.hex_encode()

## 验证哈希签名
func _verify_signature(data: String, signature: String) -> bool:
	var expected = _generate_signature(data)
	return expected == signature

## 清除损坏的数据
func _clear_corrupted_data() -> void:
	records = {
		"survival": null,
		"multi": null
	}
	_pending_upload = {
		"survival": false,
		"multi": false
	}
	if FileAccess.file_exists(SAVE_FILE_PATH):
		DirAccess.remove_absolute(SAVE_FILE_PATH)

## 迁移旧版 Survival 记录（添加 best_wave 字段）
## 旧数据：有 completion_time_seconds 但没有 best_wave
## 迁移策略：best_wave 默认为 30（胜利波次）
func _migrate_survival_record() -> void:
	var survival_record = records.get("survival")
	if survival_record == null:
		return
	
	# 检查是否需要迁移（有时间记录但没有 best_wave）
	if not survival_record.has("best_wave") and survival_record.has("completion_time_seconds"):
		survival_record["best_wave"] = 30  # 默认胜利波次
		print("[LeaderboardManager] 迁移旧版 Survival 记录: 添加 best_wave = 30")
		save_records()
