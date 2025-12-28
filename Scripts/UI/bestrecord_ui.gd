extends CanvasLayer

## 最佳纪录界面
## 显示 Survival 和 Multi 模式的最佳纪录及上传状态

# UI 节点引用
var panel: Control
var close_btn: TextureButton
var server_ping_label: Label

# Chapter 1 (Survival 模式)
var ch1_record_label: Label
var ch1_state_label: Label
var ch1_upload_btn: TextureButton
var ch1_archived_time: Label

# Chapter 2 (Multi 模式)
var ch2_record_label: Label
var ch2_state_label: Label
var ch2_upload_btn: TextureButton
var ch2_archived_time: Label

# 删除按钮（默认隐藏，按 R 键切换显示）
var ch1_delete_btn: TextureButton
var ch2_delete_btn: TextureButton
var _delete_btns_visible: bool = false

# 状态颜色
const COLOR_UPLOADED = Color(0.2, 0.8, 0.2)   # 绿色 - 已上传
const COLOR_NOT_UPLOADED = Color(1.0, 1.0, 1.0)  # 白色 - 未上传
const COLOR_UPLOADING = Color(1.0, 1.0, 1.0)   # 白色 - 上传中
const COLOR_FAILED = Color(1.0, 0.3, 0.3)      # 红色 - 上传失败

# 上传中动画相关
var _uploading_dot_count: Dictionary = {
	"survival": 1,
	"multi": 1
}
var _uploading_timer: Timer = null

func _ready() -> void:
	# 获取节点引用
	panel = $panel
	close_btn = $panel/close
	server_ping_label = panel.get_node("MarginContainer/VBoxContainer/serverPing")
	
	# Chapter 1 节点
	var ch1_context = panel.get_node("MarginContainer/VBoxContainer/ch1-context-Container")
	ch1_record_label = ch1_context.get_node("ch1recordLabel")
	ch1_state_label = ch1_context.get_node("ch1stateLabel")
	ch1_upload_btn = ch1_context.get_node("ch1-upload")
	ch1_archived_time = panel.get_node("MarginContainer/VBoxContainer/ch1-time-Container/ch1-archived-time")
	
	# Chapter 2 节点
	var ch2_context = panel.get_node("MarginContainer/VBoxContainer/ch2-context-Container")
	ch2_record_label = ch2_context.get_node("ch2recordLabel")
	ch2_state_label = ch2_context.get_node("ch2stateLabel")
	ch2_upload_btn = ch2_context.get_node("ch2-upload")
	ch2_archived_time = panel.get_node("MarginContainer/VBoxContainer/ch2-time-Container/ch2-archived-time")
	
	# 删除按钮节点
	ch1_delete_btn = ch1_context.get_node("ch1-delete")
	ch2_delete_btn = ch2_context.get_node("ch2-delete")
	
	# 默认隐藏删除按钮
	ch1_delete_btn.visible = false
	ch2_delete_btn.visible = false
	
	# 连接关闭按钮
	close_btn.pressed.connect(_on_close_pressed)
	
	# 连接上传按钮
	ch1_upload_btn.pressed.connect(_on_ch1_upload_pressed)
	ch2_upload_btn.pressed.connect(_on_ch2_upload_pressed)
	
	# 连接删除按钮
	ch1_delete_btn.pressed.connect(_on_ch1_delete_pressed)
	ch2_delete_btn.pressed.connect(_on_ch2_delete_pressed)
	
	# 监听上传状态变化
	LeaderboardManager.upload_state_changed.connect(_on_upload_state_changed)
	
	# 创建上传动画计时器
	_uploading_timer = Timer.new()
	_uploading_timer.wait_time = 0.5
	_uploading_timer.timeout.connect(_on_uploading_timer_timeout)
	add_child(_uploading_timer)
	
	# 刷新显示
	_refresh_display()
	
	# 检查服务器连接
	_check_server_connection()

func _input(event: InputEvent) -> void:
	# 按 R 键切换删除按钮的显示/隐藏
	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		_toggle_delete_buttons()

## 切换删除按钮的显示/隐藏
func _toggle_delete_buttons() -> void:
	_delete_btns_visible = not _delete_btns_visible
	ch1_delete_btn.visible = _delete_btns_visible
	ch2_delete_btn.visible = _delete_btns_visible
	print("[BestRecordUI] 删除按钮 %s" % ("显示" if _delete_btns_visible else "隐藏"))

func _on_close_pressed() -> void:
	# 停止计时器
	if _uploading_timer:
		_uploading_timer.stop()
	queue_free()

## 刷新所有显示
func _refresh_display() -> void:
	_refresh_survival_display()
	_refresh_multi_display()

## 刷新 Survival 模式显示
func _refresh_survival_display() -> void:
	var record = LeaderboardManager.get_survival_record()
	
	if record.is_empty():
		ch1_record_label.text = "暂无纪录"
		ch1_archived_time.text = "暂无"
		ch1_state_label.text = ""
		ch1_upload_btn.visible = false
		return
	
	# 显示纪录 - 格式: WAVE xx / xx分xx秒xx
	var best_wave = record.get("best_wave", 30)
	var time_seconds = record.get("completion_time_seconds", 0.0)
	ch1_record_label.text = "WAVE %d / %s" % [best_wave, _format_time(time_seconds)]
	
	# 显示达成时间
	var completed_at = record.get("completed_at", "")
	ch1_archived_time.text = _format_archived_time(completed_at)
	
	# 显示上传状态
	_update_upload_state_display("survival")

## 刷新 Multi 模式显示
func _refresh_multi_display() -> void:
	var record = LeaderboardManager.get_multi_record()
	
	if record.is_empty():
		ch2_record_label.text = "暂无纪录"
		ch2_archived_time.text = "暂无"
		ch2_state_label.text = ""
		ch2_upload_btn.visible = false
		return
	
	# 显示纪录 - 格式: WAVE xx
	var best_wave = record.get("best_wave", 0)
	ch2_record_label.text = "WAVE %d" % best_wave
	
	# 显示达成时间
	var achieved_at = record.get("achieved_at", "")
	ch2_archived_time.text = _format_archived_time(achieved_at)
	
	# 显示上传状态
	_update_upload_state_display("multi")

## 更新上传状态显示
func _update_upload_state_display(mode_id: String) -> void:
	var state_label: Label
	var upload_btn: TextureButton
	
	if mode_id == "survival":
		state_label = ch1_state_label
		upload_btn = ch1_upload_btn
	else:
		state_label = ch2_state_label
		upload_btn = ch2_upload_btn
	
	var upload_state = LeaderboardManager.get_upload_state(mode_id)
	
	match upload_state:
		"idle":
			# 已上传
			state_label.text = "已上传"
			state_label.modulate = COLOR_UPLOADED
			upload_btn.visible = false
			_stop_uploading_animation_if_needed()
		"uploading":
			# 上传中
			_uploading_dot_count[mode_id] = 1
			state_label.text = "上传中."
			state_label.modulate = COLOR_UPLOADING
			upload_btn.visible = true
			upload_btn.disabled = true
			_start_uploading_animation()
		"pending":
			# 未上传（待上传）
			state_label.text = "未上传"
			state_label.modulate = COLOR_NOT_UPLOADED
			upload_btn.visible = true
			upload_btn.disabled = false
			_stop_uploading_animation_if_needed()

## 上传状态变化回调
func _on_upload_state_changed(mode_id: String, state: String) -> void:
	var state_label: Label
	var upload_btn: TextureButton
	
	if mode_id == "survival":
		state_label = ch1_state_label
		upload_btn = ch1_upload_btn
	else:
		state_label = ch2_state_label
		upload_btn = ch2_upload_btn
	
	match state:
		"uploading":
			_uploading_dot_count[mode_id] = 1
			state_label.text = "上传中."
			state_label.modulate = COLOR_UPLOADING
			upload_btn.disabled = true
			_start_uploading_animation()
		"success":
			state_label.text = "已上传"
			state_label.modulate = COLOR_UPLOADED
			upload_btn.visible = false
			_stop_uploading_animation_if_needed()
		"failed":
			state_label.text = "上传失败"
			state_label.modulate = COLOR_FAILED
			upload_btn.disabled = false
			_stop_uploading_animation_if_needed()

## 开始上传动画
func _start_uploading_animation() -> void:
	if _uploading_timer and not _uploading_timer.is_stopped():
		return  # 已经在运行
	if _uploading_timer:
		_uploading_timer.start()

## 检查是否需要停止上传动画
func _stop_uploading_animation_if_needed() -> void:
	# 检查是否还有任何模式在上传中
	var survival_uploading = LeaderboardManager.get_upload_state("survival") == "uploading"
	var multi_uploading = LeaderboardManager.get_upload_state("multi") == "uploading"
	
	if not survival_uploading and not multi_uploading:
		if _uploading_timer:
			_uploading_timer.stop()

## 上传动画计时器回调
func _on_uploading_timer_timeout() -> void:
	# 更新 Survival 模式动画
	if LeaderboardManager.get_upload_state("survival") == "uploading":
		_uploading_dot_count["survival"] = (_uploading_dot_count["survival"] % 3) + 1
		var dots = ".".repeat(_uploading_dot_count["survival"])
		ch1_state_label.text = "上传中" + dots
	
	# 更新 Multi 模式动画
	if LeaderboardManager.get_upload_state("multi") == "uploading":
		_uploading_dot_count["multi"] = (_uploading_dot_count["multi"] % 3) + 1
		var dots = ".".repeat(_uploading_dot_count["multi"])
		ch2_state_label.text = "上传中" + dots

## 检查服务器连接状态
func _check_server_connection() -> void:
	# 默认隐藏（假设连接正常）
	server_ping_label.visible = false
	
	# 异步检查服务器连接
	var server_reachable = await ApiManager.ping_server()
	
	# 如果连接失败，显示提示
	if not server_reachable:
		server_ping_label.visible = true
		print("[BestRecordUI] 服务器连接失败")
	else:
		server_ping_label.visible = false
		print("[BestRecordUI] 服务器连接正常")

## 点击 Survival 模式上传按钮
func _on_ch1_upload_pressed() -> void:
	LeaderboardManager.manual_upload("survival")

## 点击 Multi 模式上传按钮
func _on_ch2_upload_pressed() -> void:
	LeaderboardManager.manual_upload("multi")

## 点击 Survival 模式删除按钮
func _on_ch1_delete_pressed() -> void:
	LeaderboardManager.clear_record("survival")
	_refresh_survival_display()
	print("[BestRecordUI] 已清空 Survival 模式纪录")

## 点击 Multi 模式删除按钮
func _on_ch2_delete_pressed() -> void:
	LeaderboardManager.clear_record("multi")
	_refresh_multi_display()
	print("[BestRecordUI] 已清空 Multi 模式纪录")

## 格式化时间为 xx分xx秒xx
func _format_time(time_seconds: float) -> String:
	var total_seconds: int = int(time_seconds)
	@warning_ignore("integer_division")
	var minutes: int = total_seconds / 60
	var seconds: int = total_seconds % 60
	var centiseconds: int = int((time_seconds - total_seconds) * 100)
	
	return "%d分%02d秒%02d" % [minutes, seconds, centiseconds]

## 格式化达成时间
## 输入: ISO 8601 格式 "2024-12-24T12:48:00Z"
## 输出: "2024年12月24日12时48分"
func _format_archived_time(iso_time: String) -> String:
	if iso_time.is_empty():
		return "暂无"
	
	# 解析 ISO 8601 格式
	# 格式: "2024-12-24T12:48:00Z"
	var parts = iso_time.split("T")
	if parts.size() < 2:
		return iso_time
	
	var date_part = parts[0]
	var time_part = parts[1].replace("Z", "")
	
	var date_components = date_part.split("-")
	var time_components = time_part.split(":")
	
	if date_components.size() < 3 or time_components.size() < 2:
		return iso_time
	
	var year = date_components[0]
	var month = date_components[1].lstrip("0")
	var day = date_components[2].lstrip("0")
	var hour = time_components[0].lstrip("0")
	var minute = time_components[1]
	
	# 处理空字符串（比如 00 变成空）
	if hour.is_empty():
		hour = "0"
	if month.is_empty():
		month = "1"
	if day.is_empty():
		day = "1"
	
	return "%s年%s月%s日%s时%s分" % [year, month, day, hour, minute]
