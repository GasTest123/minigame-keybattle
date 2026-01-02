extends Node2D
class_name GraveOnline

## 联网模式墓碑
## 玩家死亡时生成，显示玩家名字
## 其他玩家可以靠近读条救援
## 玩家复活后移除
##
## 优化：减少 RPC 调用
## - 开始救援：服务器广播开始，客户端自己计算进度
## - 中途停止：服务器广播停止，客户端重置
## - 救援成功：服务器复活玩家并移除墓碑

## 节点引用
@onready var grave_sprite: Sprite2D = $GraveSprite
@onready var name_label: Label = $GraveSprite/NameLabel
@onready var range_circle: Sprite2D = $RangeCircle
@onready var progress_bar: ProgressBar = $ProgressBar
@onready var time_label: Label = $ProgressBar/TimeLabel

## 绑定的玩家 peer_id（死亡的玩家）
var bound_peer_id: int = 0

## 玩家显示名
var player_name: String = ""

## 玩家角色类型（用于判断是否可被救援）
var player_role_id: String = ""

## 救援范围
const RESCUE_RANGE: float = 400.0

## 救援读条时间（秒）
const RESCUE_TIME: float = 3.0

## Boss 自动复活时间（秒）
const BOSS_AUTO_REVIVE_TIME: float = 15.0

## Boss 自动复活相关
var _is_boss_grave: bool = false
var _boss_auto_revive_end_time_ms: int = 0  # 客户端本地的预计结束时间（毫秒）
var _server_boss_auto_revive_end_time_ms: int = 0  # 服务器端预计结束时间

## 服务器端：读条相关
var rescue_progress: float = 0.0
var is_rescuing: bool = false
var rescuer_peer_id: int = 0  # 当前救援者的 peer_id
var _server_rescue_end_time_ms: int = 0  # 服务器预计救援结束时间（毫秒）

## 客户端：本地显示相关
var _client_is_showing: bool = false
var _client_rescue_end_time_ms: int = 0  # 客户端本地的预计结束时间（毫秒）

func _ready() -> void:
	add_to_group("grave_online")
	z_index = 20
	
	# 初始隐藏范围圈和进度条
	if range_circle:
		range_circle.visible = false
		_setup_range_circle()
	if progress_bar:
		progress_bar.visible = false
		progress_bar.value = 0

func _process(delta: float) -> void:
	if NetworkManager.is_server():
		_server_process(delta)
	else:
		_client_process(delta)
	
	# Boss 自动复活倒计时显示（服务器和客户端都需要）
	if _is_boss_grave:
		_update_boss_auto_revive_display()

## 服务器端处理
func _server_process(delta: float) -> void:
	# 检测范围内的活着的其他玩家
	var rescuer = _find_rescuer_in_range()
	
	if rescuer:
		var current_rescuer_id = rescuer.peer_id
		
		# 如果换了救援者，重置进度
		if rescuer_peer_id != current_rescuer_id:
			rescuer_peer_id = current_rescuer_id
			rescue_progress = 0.0
		
		# 开始或继续读条
		if not is_rescuing:
			_start_rescue()
		
		# 更新进度
		rescue_progress += delta
		
		# 服务器本地更新显示
		_update_local_display(rescue_progress / RESCUE_TIME)
		
		# 读条完成
		if rescue_progress >= RESCUE_TIME:
			_complete_rescue(rescuer)
	else:
		# 没有救援者，停止读条
		if is_rescuing:
			_stop_rescue()

## 客户端处理：基于结束时间计算进度
func _client_process(_delta: float) -> void:
	if not _client_is_showing:
		return
	
	# 基于结束时间计算剩余时间和进度
	var current_time_ms = Time.get_ticks_msec()
	var remaining_ms = _client_rescue_end_time_ms - current_time_ms
	var remaining_time = float(remaining_ms) / 1000.0
	
	# 计算进度（0.0 到 1.0）
	var progress = 1.0 - (remaining_time / RESCUE_TIME)
	progress = clampf(progress, 0.0, 1.0)
	
	# 更新本地显示
	_update_local_display(progress)
	
	# 进度达到100%时，客户端等待服务器的移除指令
	# 不需要主动做任何事，服务器会广播移除墓碑

## 设置墓碑数据
func setup(peer_id: int, display_name: String, role_id: String = "") -> void:
	bound_peer_id = peer_id
	player_name = display_name
	player_role_id = role_id
	_is_boss_grave = (role_id == NetworkPlayerManager.ROLE_BOSS)
	
	# 更新名字标签
	if name_label:
		name_label.text = display_name
	
	# Boss 墓碑：隐藏救援圈（Boss 不能被救援）
	if _is_boss_grave:
		if range_circle:
			range_circle.visible = false
	
	print("[GraveOnline] 墓碑设置完成 | peer_id=%d, name=%s, role=%s, is_boss=%s" % [peer_id, display_name, role_id, str(_is_boss_grave)])

## 设置范围圈大小
func _setup_range_circle() -> void:
	if not range_circle or not range_circle.texture:
		return
	
	var target_diameter = RESCUE_RANGE * 2
	var texture_size = range_circle.texture.get_size().x
	if texture_size > 0:
		range_circle.scale = Vector2.ONE * (target_diameter / texture_size)

## 查找范围内可以救援的玩家
func _find_rescuer_in_range() -> Node:
	# Boss 墓碑不能被救援
	if player_role_id == NetworkPlayerManager.ROLE_BOSS:
		return null
	
	var players = NetworkPlayerManager.players
	
	for peer_id in players.keys():
		# 跳过死亡的玩家自己
		if peer_id == bound_peer_id:
			continue
		
		var player = players[peer_id]
		if not player or not is_instance_valid(player):
			continue
		
		# 玩家必须活着
		if player.now_hp <= 0:
			continue
		
		# Boss 不能救援其他玩家
		var rescuer_role = player.get("player_role_id")
		if rescuer_role == NetworkPlayerManager.ROLE_BOSS:
			continue
		
		# 检查距离
		var distance = player.global_position.distance_to(global_position)
		if distance <= RESCUE_RANGE:
			return player
	
	return null

## 开始救援（服务器端）
func _start_rescue() -> void:
	is_rescuing = true
	rescue_progress = 0.0
	
	# 计算预计结束时间（当前时间 + 救援时长）
	var remaining_time_ms = int(RESCUE_TIME * 1000)
	_server_rescue_end_time_ms = Time.get_ticks_msec() + remaining_time_ms
	
	print("[GraveOnline] 开始救援读条 | 墓碑=%d, 救援者=%d, 预计结束时间=%d" % [bound_peer_id, rescuer_peer_id, _server_rescue_end_time_ms])
	
	# 广播通知所有客户端开始救援，传递剩余时间（毫秒）
	NetworkPlayerManager.broadcast_grave_rescue_start(bound_peer_id, remaining_time_ms)

## 停止救援（服务器端）
func _stop_rescue() -> void:
	is_rescuing = false
	rescue_progress = 0.0
	rescuer_peer_id = 0
	print("[GraveOnline] 停止救援读条 | 墓碑=%d" % bound_peer_id)
	
	# 广播通知所有客户端停止救援（只发一次）
	NetworkPlayerManager.broadcast_grave_rescue_stop(bound_peer_id)

## 完成救援（服务器端）
func _complete_rescue(rescuer: Node) -> void:
	print("[GraveOnline] 救援完成 | 墓碑=%d, 救援者=%d" % [bound_peer_id, rescuer.peer_id])
	
	# 通知 NetworkPlayerManager 处理救援（会移除墓碑）
	NetworkPlayerManager.handle_grave_rescue(bound_peer_id, rescuer.peer_id)
	
	# 重置状态
	is_rescuing = false
	rescue_progress = 0.0
	rescuer_peer_id = 0

## 更新本地显示
func _update_local_display(progress: float) -> void:
	progress = clampf(progress, 0.0, 1.0)
	
	if range_circle:
		range_circle.visible = true
	
	if progress_bar:
		progress_bar.visible = true
		progress_bar.value = progress * 100.0
	
	if time_label:
		var time_left = RESCUE_TIME * (1.0 - progress)
		time_label.text = "%.1f" % max(0.0, time_left)

## 客户端：开始显示救援进度（由 NetworkPlayerManager 调用）
## remaining_time_ms: 剩余救援时间（毫秒），用于同步所有客户端的进度
func start_rescue_display(remaining_time_ms: int) -> void:
	_client_is_showing = true
	
	# 根据服务器发来的剩余时间，计算本地的预计结束时间
	_client_rescue_end_time_ms = Time.get_ticks_msec() + remaining_time_ms
	
	if range_circle:
		range_circle.visible = true
	if progress_bar:
		progress_bar.visible = true
		progress_bar.value = 0
	if time_label:
		time_label.text = "%.1f" % RESCUE_TIME

## 客户端：停止显示救援进度（由 NetworkPlayerManager 调用）
func stop_rescue_display() -> void:
	_client_is_showing = false
	_client_rescue_end_time_ms = 0
	
	if range_circle:
		range_circle.visible = false
	if progress_bar:
		progress_bar.visible = false
		progress_bar.value = 0
	if time_label:
		time_label.text = ""

## ==================== Boss 自动复活相关 ====================

## 服务器端：启动 Boss 自动复活计时器
func start_boss_auto_revive_timer() -> void:
	if not NetworkManager.is_server():
		return
	
	if not _is_boss_grave:
		return
	
	# 计算自动复活结束时间
	_server_boss_auto_revive_end_time_ms = Time.get_ticks_msec() + int(BOSS_AUTO_REVIVE_TIME * 1000)
	_boss_auto_revive_end_time_ms = _server_boss_auto_revive_end_time_ms
	
	print("[GraveOnline] Boss 自动复活计时器启动 | peer_id=%d, 结束时间=%d" % [bound_peer_id, _server_boss_auto_revive_end_time_ms])
	
	# 广播给所有客户端
	NetworkPlayerManager.broadcast_boss_auto_revive_start(bound_peer_id, int(BOSS_AUTO_REVIVE_TIME * 1000))

## 客户端：开始显示 Boss 自动复活倒计时（由 NetworkPlayerManager 调用）
func start_boss_auto_revive_display(remaining_time_ms: int) -> void:
	_boss_auto_revive_end_time_ms = Time.get_ticks_msec() + remaining_time_ms
	
	# 显示进度条（用于倒计时）
	if progress_bar:
		progress_bar.visible = true
		progress_bar.value = 100  # Boss 倒计时从 100% 开始倒数
	if time_label:
		time_label.text = "%.1f" % BOSS_AUTO_REVIVE_TIME
	
	print("[GraveOnline] Boss 自动复活倒计时开始显示 | peer_id=%d, remaining_ms=%d" % [bound_peer_id, remaining_time_ms])

## 更新 Boss 自动复活倒计时显示
func _update_boss_auto_revive_display() -> void:
	if _boss_auto_revive_end_time_ms <= 0:
		return
	
	var current_time_ms = Time.get_ticks_msec()
	var remaining_ms = _boss_auto_revive_end_time_ms - current_time_ms
	var remaining_time = float(remaining_ms) / 1000.0
	
	if remaining_time <= 0:
		remaining_time = 0
		# 服务器端：触发自动复活
		if NetworkManager.is_server():
			_boss_auto_revive_end_time_ms = 0  # 防止重复触发
			_trigger_boss_auto_revive()
		return
	
	# 计算进度（从 100% 倒数到 0%）
	var progress = remaining_time / BOSS_AUTO_REVIVE_TIME
	progress = clampf(progress, 0.0, 1.0)
	
	if progress_bar:
		progress_bar.visible = true
		progress_bar.value = progress * 100.0
	
	if time_label:
		time_label.text = "%.1f" % remaining_time

## 服务器端：触发 Boss 自动复活
func _trigger_boss_auto_revive() -> void:
	if not NetworkManager.is_server():
		return
	
	print("[GraveOnline] Boss 自动复活触发 | peer_id=%d" % bound_peer_id)
	
	# 调用 NetworkPlayerManager 执行复活
	NetworkPlayerManager._server_revive_player_auto(bound_peer_id)

## ==================== 墓碑清理 ====================

## 清理墓碑
func cleanup() -> void:
	queue_free()
