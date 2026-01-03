extends Control

@onready var chapter1_btn: TextureButton = $bg/MarginContainer/HBoxContainer/chaper1panel/chaper1beginBtn
@onready var chapter2_btn: TextureButton = $bg/MarginContainer/HBoxContainer/chaper2panel/chaper2beginBtn
@onready var chapter3_btn: TextureButton = $bg/MarginContainer/HBoxContainer/chaper3panel/chaper3beginBtn
@onready var back_button: TextureButton = $bg/backButton

## Chapter 3（联网模式）文案/按钮
@onready var chapter3_info1_label: RichTextLabel = $bg/MarginContainer/HBoxContainer/chaper3panel/chaper3text/RichTextLabel4
@onready var chapter3_info2_label: RichTextLabel = $bg/MarginContainer/HBoxContainer/chaper3panel/chaper3text/RichTextLabel5
@onready var chapter3_btn_label: Label = $bg/MarginContainer/HBoxContainer/chaper3panel/chaper3beginBtn/beginLabel

## 个人记录显示标签
@onready var chapter1_record_label: RichTextLabel = $bg/MarginContainer/HBoxContainer/chaper1panel/chaper1text/selfrecordLabel
@onready var chapter2_record_label: RichTextLabel = $bg/MarginContainer/HBoxContainer/chaper2panel/chaper2text/selfrecordLabel

## 联网模式配置
const ONLINE_MODE_ID := "online"
const ONLINE_MAP_ID := "online_stage_1"
const ONLINE_SCENE_PATH := "res://scenes/map/online_map.tscn"

var _ip_address: String = ""
var _port: int = NetworkManager.DEFAULT_PORT
var _online_role: String = ""  # "s" = server, "c" = client, "" = disabled
var _is_waiting_for_join: bool = false
var _is_discovering_servers: bool = false
var _discovered_servers: Array = []

# 客户端自动发现服务器：进入页面后执行一个 loop，未找到则每 1 秒重试，找到则退出
const _DISCOVERY_RETRY_SEC := 1.0
var _is_discovery_loop_running: bool = false

func _ready() -> void:
	# 播放标题BGM
	BGMManager.play_bgm("title")
	print("[LevelSelect] 关卡选择界面就绪")
	
	# 检测联网模式启动参数
	_check_online_mode_args()
	
	# 连接按钮信号
	if chapter1_btn:
		chapter1_btn.pressed.connect(_on_chapter1_begin_pressed)
	
	if chapter2_btn:
		chapter2_btn.pressed.connect(_on_chapter2_begin_pressed)
	
	if chapter3_btn:
		chapter3_btn.pressed.connect(_on_chapter3_begin_pressed)
	
	if back_button:
		back_button.pressed.connect(_on_back_button_pressed)
	
	# 连接网络信号
	_connect_network_signals()

	# 更新联网模式UI
	_update_online_chapter3_ui()

	# 客户端：搜索同网段可用服务器
	if _online_role == "c" and _ip_address == "":
		_start_discovery_loop()
	
	# 更新个人记录显示
	_update_record_labels()


func _exit_tree() -> void:
	_is_discovery_loop_running = false
	_disconnect_network_signals()


func _on_chapter1_begin_pressed() -> void:
	# Chapter 1: 孤勇者模式 - Survival
	GameMain.current_mode_id = "survival"
	print("[LevelSelect] 选择 Chapter 1: Survival 模式")
	get_tree().change_scene_to_file("res://scenes/UI/Class_choose.tscn")


func _on_chapter2_begin_pressed() -> void:
	# Chapter 2: 同心同力模式 - Multi
	GameMain.current_mode_id = "multi"
	print("[LevelSelect] 选择 Chapter 2: Multi 模式")
	
	# 检查玩家的最高波次，如果大于0则跳过动画直接进入选择界面
	var multi_record = LeaderboardManager.get_multi_record()
	var best_wave = multi_record.get("best_wave", 0)
	
	if best_wave > 0:
		print("[LevelSelect] 玩家已有记录(最高波次: %d)，跳过动画" % best_wave)
		get_tree().change_scene_to_file("res://scenes/UI/Class_choose.tscn")
	else:
		print("[LevelSelect] 玩家首次进入，播放章节动画")
		get_tree().change_scene_to_file("res://scenes/UI/cutscene_chapter2.tscn")


func _on_chapter3_begin_pressed() -> void:
	# Chapter 3: 年会模式 - Online
	print("[LevelSelect] 选择 Chapter 3: Online 模式")
	
	GameMain.current_mode_id = ONLINE_MODE_ID
	GameMain.current_map_id = ONLINE_MAP_ID
	# ModeRegistry.set_current_mode(ONLINE_MODE_ID)
	# MapRegistry.set_current_map(ONLINE_MAP_ID)

	if _online_role == "s":
		# server：启动/停止服务
		if NetworkManager.is_server():
			NetworkManager.stop_network()
			_update_online_chapter3_ui()
		else:
			_start_as_server()
	elif _online_role == "c":
		# client：断开/重连
		if NetworkManager.is_client() or _is_waiting_for_join:
			NetworkManager.stop_network()
			_update_online_chapter3_ui()
		else:
			# 还未发现服务器地址时，不允许点击连接
			if _ip_address == "":
				print("[LevelSelect] 客户端尚未发现服务器，连接按钮无效")
				return
			_start_as_client()
			_update_online_chapter3_ui()
	else:
		print("[LevelSelect] 联网模式未启用（需要 -s 或 -c 启动参数）")
		_update_online_chapter3_ui()


func _on_back_button_pressed() -> void:
	print("[LevelSelect] 返回主菜单")
	get_tree().change_scene_to_file("res://scenes/UI/main_title.tscn")


## 更新个人记录显示
func _update_record_labels() -> void:
	# 更新 Chapter 1 (Survival 模式) 记录
	if chapter1_record_label:
		var survival_record = LeaderboardManager.get_survival_record()
		if survival_record.is_empty():
			chapter1_record_label.text = "[i]个人最高波次：[color=#ea33bf]--[/color][/i]"
		else:
			var best_wave = survival_record.get("best_wave", 30)
			if best_wave >= 30:
				# 已通关，显示最速通关时间
				var time_seconds = survival_record.get("completion_time_seconds", 0.0)
				var time_str = _format_time(time_seconds)
				chapter1_record_label.text = "[i]个人最速通关：[color=#ea33bf]%s[/color][/i]" % time_str
			else:
				# 未通关，显示最高波次
				chapter1_record_label.text = "[i]个人最高波次：[color=#ea33bf]%d[/color][/i]" % best_wave
	
	# 更新 Chapter 2 (Multi 模式) 记录
	if chapter2_record_label:
		var multi_record = LeaderboardManager.get_multi_record()
		if multi_record.is_empty():
			chapter2_record_label.text = "[i]个人最高波次：[color=#ea33bf]--[/color][/i]"
		else:
			var best_wave = multi_record.get("best_wave", 0)
			chapter2_record_label.text = "[i]个人最高波次：[color=#ea33bf]%d[/color][/i]" % best_wave

## 格式化时间显示 (秒 -> 分'秒''毫秒)
func _format_time(seconds: float) -> String:
	var total_minutes = int(seconds) / 60
	var secs = int(seconds) % 60
	var centiseconds = int((seconds - int(seconds)) * 100)
	
	return "%d'%02d''%02d" % [total_minutes, secs, centiseconds]

## ==================== 联网模式 ====================

## 检测联网模式启动参数
func _check_online_mode_args() -> void:
	var args := OS.get_cmdline_args()
	for i in args.size():
		var arg := args[i]
		if arg == "--server":
			_online_role = "s"
			_port = NetworkManager.DEFAULT_PORT
			# 支持：--server [[:]port]
			if i + 1 < args.size():
				var port_token := String(args[i + 1]).strip_edges()
				if port_token.begins_with(":"):
					port_token = port_token.substr(1)
				if port_token.is_valid_int():
					var parsed_port := int(port_token)
					if parsed_port > 0 and parsed_port <= 65535:
						_port = parsed_port
			print("[LevelSelect] 检测到服务器模式启动参数，端口: %d" % _port)
			return
		if arg == "--client" or arg == "-c":
			_online_role = "c"
			_port = NetworkManager.DEFAULT_PORT
			# 支持：--client [ip[:port]] 或 --client [[:]port]
			if i + 1 < args.size():
				var addr_token := String(args[i + 1]).strip_edges()
				var host_part := ""
				var port_part := ""
				if addr_token != "":
					# 格式 1：[:]port
					if addr_token.begins_with(":"):
						port_part = addr_token.substr(1)
					# 格式 2：port
					elif addr_token.is_valid_int():
						port_part = addr_token
					else:
						# 格式 3：ip[:port]
						var last_colon := addr_token.rfind(":")
						if last_colon > 0:
							host_part = addr_token.substr(0, last_colon)
							port_part = addr_token.substr(last_colon + 1)
						else:
							host_part = addr_token
				if port_part != "" and port_part.is_valid_int():
					var parsed_port := int(port_part)
					if parsed_port > 0 and parsed_port <= 65535:
						_port = parsed_port
				# host_part 为空表示使用自动发现（_ip_address 保持为空）
				if host_part != "" and IP.resolve_hostname_addresses(host_part, IP.TYPE_ANY).size() > 0:
					_ip_address = host_part
			print("[LevelSelect] 检测到客户端模式启动参数，目标: %s:%d" % [_ip_address, _port])
			return
	_online_role = ""
	_port = NetworkManager.DEFAULT_PORT

## 作为服务器启动
func _start_as_server() -> void:
	if not NetworkManager.start_host(_port):
		print("[LevelSelect] 主机启动失败，请检查端口是否被占用")
		_update_online_chapter3_ui()
		return
	print("[LevelSelect] 主机已启动，等待其他玩家加入...")
	await SceneCleanupManager.change_scene_safely_keep_mode(ONLINE_SCENE_PATH)

## 作为客户端加入
func _start_as_client() -> void:
	if _ip_address == "":
		return
	if NetworkManager.start_client(_ip_address, _port):
		print("[LevelSelect] 正在连接 %s:%d ..." % [_ip_address, _port])
		_is_waiting_for_join = true
		_update_online_chapter3_ui()
	else:
		print("[LevelSelect] 连接失败，请确认地址与端口")
		_update_online_chapter3_ui()

## 连接网络信号
func _connect_network_signals() -> void:
	if not NetworkManager.network_started.is_connected(_on_network_started):
		NetworkManager.network_started.connect(_on_network_started)
	if not NetworkManager.network_stopped.is_connected(_on_network_stopped):
		NetworkManager.network_stopped.connect(_on_network_stopped)
	if not NetworkManager.connection_failed.is_connected(_on_network_connection_failed):
		NetworkManager.connection_failed.connect(_on_network_connection_failed)
	if not NetworkManager.server_disconnected.is_connected(_on_network_server_disconnected):
		NetworkManager.server_disconnected.connect(_on_network_server_disconnected)
	if not NetworkManager.connected_to_server.is_connected(_on_network_connected_to_server):
		NetworkManager.connected_to_server.connect(_on_network_connected_to_server)

## 断开网络信号
func _disconnect_network_signals() -> void:
	if NetworkManager.network_started.is_connected(_on_network_started):
		NetworkManager.network_started.disconnect(_on_network_started)
	if NetworkManager.network_stopped.is_connected(_on_network_stopped):
		NetworkManager.network_stopped.disconnect(_on_network_stopped)
	if NetworkManager.connection_failed.is_connected(_on_network_connection_failed):
		NetworkManager.connection_failed.disconnect(_on_network_connection_failed)
	if NetworkManager.server_disconnected.is_connected(_on_network_server_disconnected):
		NetworkManager.server_disconnected.disconnect(_on_network_server_disconnected)
	if NetworkManager.connected_to_server.is_connected(_on_network_connected_to_server):
		NetworkManager.connected_to_server.disconnect(_on_network_connected_to_server)

func _on_network_started(is_server: bool) -> void:
	if is_server:
		print("[LevelSelect] 主机启动成功")
	else:
		print("[LevelSelect] 正在尝试连接服务器...")
	_update_online_chapter3_ui()

func _on_network_stopped() -> void:
	if _is_waiting_for_join:
		print("[LevelSelect] 连接已关闭")
	_is_waiting_for_join = false
	if _online_role == "c":
		_start_discovery_loop()
	_update_online_chapter3_ui()

func _on_network_connection_failed() -> void:
	print("[LevelSelect] 连接失败，请重试")
	_is_waiting_for_join = false
	if _online_role == "c":
		_start_discovery_loop()
	_update_online_chapter3_ui()

func _on_network_server_disconnected() -> void:
	print("[LevelSelect] 与主机断开连接")
	_is_waiting_for_join = false
	if _online_role == "c":
		_start_discovery_loop()
	_update_online_chapter3_ui()

func _on_network_connected_to_server() -> void:
	if not _is_waiting_for_join:
		return
	print("[LevelSelect] 连接成功，正在进入战场...")
	_is_waiting_for_join = false
	_is_discovery_loop_running = false
	_update_online_chapter3_ui()
	await SceneCleanupManager.change_scene_safely_keep_mode(ONLINE_SCENE_PATH)

func _update_online_chapter3_ui() -> void:
	# 根据联网模式参数显示/隐藏年会模式按钮，并刷新 Chapter 3 文案
	if chapter3_btn:
		chapter3_btn.disabled = (_online_role == "")
		chapter3_btn.modulate.a = 0.5 if _online_role == "" else 1.0

	if _online_role == "":
		if chapter3_info1_label:
			chapter3_info1_label.text = "[i]启动参数 --server/--client[/i]"
		if chapter3_btn_label:
			chapter3_btn_label.text = "进  入"
		return

	if _online_role == "s":
		if chapter3_info1_label:
			var host_ip := NetworkManager.get_local_ipv4()
			chapter3_info1_label.text = "[i]Server IP：[color=#ff6600]%s:%d[/color][/i]" % [host_ip, _port]
		if chapter3_info2_label:
			if "enable_role_impostor" in NetworkPlayerManager and NetworkPlayerManager.enable_role_impostor:
				chapter3_info2_label.text = "[i]【 🎭 [color=#ff6600]开启内鬼[/color] 】[/i]"
			else:
				chapter3_info2_label.text = "[i][/i]"
		if chapter3_btn_label:
			chapter3_btn_label.text = "停止服务" if NetworkManager.is_server() else "启动服务"
		return

	if _online_role == "c":
		if chapter3_info1_label:
			if _ip_address != "":
				chapter3_info1_label.text = "[i]Server IP：\n[color=#ff6600]%s:%d[/color][/i]" % [_ip_address, _port]
			elif _is_discovering_servers:
				chapter3_info1_label.text = "[i]Server IP：\n[color=#ff6600]正在搜索服务器...[/color][/i]"
			else:
				chapter3_info1_label.text = "[i]Server IP：\n[color=#ff6600]正在搜索服务器...[/color][/i]"
		if chapter3_info2_label:
			chapter3_info2_label.text = "[i][/i]"
		if chapter3_btn_label:
			chapter3_btn_label.text = "断  开" if (NetworkManager.is_client() or _is_waiting_for_join) else "连  接"
		return


## ==================== 客户端：发现服务器（循环） ====================

func _start_discovery_loop() -> void:
	if _online_role != "c":
		return
	if _is_discovery_loop_running:
		return
	_is_discovery_loop_running = true
	call_deferred("_run_discovery_loop")

func _run_discovery_loop() -> void:
	if _online_role != "c":
		return
	# 异步循环：未找到则等待 1 秒继续找；找到或条件不满足则退出
	while _is_discovery_loop_running:
		if _is_waiting_for_join or NetworkManager.is_client():
			break
		if _discovered_servers.size() > 0:
			break
		await _discover_servers_for_client()
		if _discovered_servers.size() > 0:
			break
		# 未找到：等 1 秒再试
		await get_tree().create_timer(_DISCOVERY_RETRY_SEC).timeout

	_is_discovery_loop_running = false

## 客户端：搜索同网段可用服务器并（如需要）自动选用第一个
func _discover_servers_for_client() -> void:
	if _online_role != "c":
		return
	if _is_waiting_for_join or NetworkManager.is_client():
		return
	if _is_discovering_servers:
		return

	_is_discovering_servers = true
	_update_online_chapter3_ui()

	# 扫描本机所在 /24 网段（1..254）
	var servers: Array = await NetworkManager.discover_lan_servers(1, 32, 50, 1, _port)
	_discovered_servers = servers

	# 若当前还是默认地址，则自动选用第一个发现到的服务器
	if _ip_address == "" and _discovered_servers.size() > 0:
		var s: Dictionary = _discovered_servers[0] as Dictionary
		if not s.is_empty() and s.has("ip") and s.has("port"):
			_ip_address = String(s.get("ip", "127.0.0.1"))
			_port = int(s.get("port", _port))

	_is_discovering_servers = false
	_update_online_chapter3_ui()
	return
