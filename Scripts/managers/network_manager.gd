extends Node

## 全局网络管理器 - 负责多人联机模式的底层连接与事件管理
## TODO: 后续补充房间列表、断线重连等完整逻辑

signal network_started(is_server: bool)
signal network_stopped()
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal connection_failed()
signal server_disconnected()
signal connected_to_server()

# 默认端口与Tick配置，可在GameConfig后续补充
const DEFAULT_PORT: int = 19010
const DEFAULT_MAX_CLIENTS: int = 5

var _multiplayer_api: MultiplayerAPI = null
var _is_server: bool = false
var _is_started: bool = false

func _ready() -> void:
	_multiplayer_api = MultiplayerAPI.create_default_interface()
	multiplayer.multiplayer_peer = null
	_register_signals()
	print("[NetworkManager] Ready")

func _register_signals() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)

func start_host(port: int = DEFAULT_PORT, max_clients: int = DEFAULT_MAX_CLIENTS) -> bool:
	if _is_started:
		print("[NetworkManager] Host already running")
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients)
	if err != OK:
		push_error("[NetworkManager] Failed to start host: %s" % error_string(err))
		return false
	peer.refuse_new_connections = false
	multiplayer.multiplayer_peer = peer
	_is_server = true
	_is_started = true
	print("[NetworkManager] Host started on port %d" % port)
	network_started.emit(true)
	return true

func start_client(address: String, port: int = DEFAULT_PORT) -> bool:
	if _is_started:
		print("[NetworkManager] Client already connected")
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("[NetworkManager] Failed to connect: %s" % error_string(err))
		return false
	multiplayer.multiplayer_peer = peer
	_is_server = false
	_is_started = true
	print("[NetworkManager] Connecting to %s:%d" % [address, port])
	network_started.emit(false)
	return true

func stop_network() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_is_started = false
	_is_server = false
	print("[NetworkManager] Network stopped")
	network_stopped.emit()

func is_server() -> bool:
	return _is_server and _is_started

func is_client() -> bool:
	return not _is_server and _is_started

func get_peer_id() -> int:
	return multiplayer.get_unique_id()

func get_multiplayer_peer() -> MultiplayerPeer:
	return multiplayer.multiplayer_peer

func _on_peer_connected(id: int) -> void:
	print("[NetworkManager] Peer connected: %d" % id)
	peer_connected.emit(id)

func _on_peer_disconnected(id: int) -> void:
	print("[NetworkManager] Peer disconnected: %d" % id)
	peer_disconnected.emit(id)

func _on_connection_failed() -> void:
	print("[NetworkManager] Connection failed")
	stop_network()
	connection_failed.emit()

func _on_server_disconnected() -> void:
	print("[NetworkManager] Server disconnected")
	stop_network()
	server_disconnected.emit()

func _on_connected_to_server() -> void:
	print("[NetworkManager] Connected to server")
	connected_to_server.emit()


## ==================== Local IP helpers ====================
## 获取当前机器局域网 IPv4 地址
func get_local_ipv4() -> String:
	var addrs: PackedStringArray = IP.get_local_addresses()
	var ipv4_192: PackedStringArray = PackedStringArray()
	var ipv4_10: PackedStringArray = PackedStringArray()

	for a in addrs:
		var s := String(a).strip_edges()
		if s.is_empty():
			continue
		if s.find(":") != -1:
			continue
		if s.count(".") != 3:
			continue
		if s == "0.0.0.0":
			continue
		if s == "127.0.0.1" or s.begins_with("127."):
			continue
		if s.begins_with("192.168."):
			ipv4_192.append(s)
			continue
		if s.begins_with("10."):
			ipv4_10.append(s)
			continue

	if ipv4_192.size() > 0:
		return ipv4_192[0]
	if ipv4_10.size() > 0:
		return ipv4_10[0]
	return "127.0.0.1"


## ==================== LAN discovery helpers ====================
## Client 端：不要求服务器配合，直接利用 ENet 的握手判断“该 IP:port 是否有本游戏的 ENet server 在监听”
## 扫描本机所在 /24 网段（例如 192.168.1.*），并返回可连接的服务器列表：
## [{ "ip": "192.168.1.10", "port": 19010 }, ...]
func probe_enet_server(ip: String, port: int = DEFAULT_PORT, timeout_ms: int = 50) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		return false

	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < timeout_ms:
		peer.poll()
		var status := peer.get_connection_status()
		if status == MultiplayerPeer.CONNECTION_CONNECTED:
			peer.close()
			return true
		if status == MultiplayerPeer.CONNECTION_DISCONNECTED:
			break
		await get_tree().process_frame

	peer.close()
	return false

func discover_lan_servers(port_from: int = 1, port_to: int = 255,timeout_per_host_ms: int = 50, max_results: int = 1, port: int = DEFAULT_PORT) -> Array:
	var results: Array = []
	var local_ip := get_local_ipv4()
	if local_ip == "127.0.0.1":
		return results

	var parts := local_ip.split(".")
	if parts.size() < 4:
		return results
	var base := "%s.%s.%s." % [parts[0], parts[1], parts[2]]

	# 扫描自己
	if await probe_enet_server(local_ip, port, timeout_per_host_ms):
		results.append({"ip": local_ip, "port": port})
		if results.size() >= max_results:
			return results

	# 扫描 1..254（跳过自己），每个 host 给一个很短的握手窗口
	for i in range(port_from, port_to):
		var ip := "%s%d" % [base, i]
		if ip == local_ip:
			continue

		if await probe_enet_server(ip, port, timeout_per_host_ms):
			results.append({"ip": ip, "port": port})
			if results.size() >= max_results:
				return results

	return results


## ==================== Cursor debug log (agent) ====================
## 仅用于 Cursor Debug Mode：写入 user://logs/cursor_debug.log
const _CURSOR_DEBUG_LOG_PATH := "user://logs/cursor_debug.log"
const _CURSOR_DEBUG_INGEST_ENDPOINT := "http://127.0.0.1:7242/ingest/bc7c6b29-7276-42e9-a65e-25c6213dc759"

func cursor_debug_log(hypothesis_id: String, location: String, message: String, data: Dictionary, run_id: String = "pre-fix") -> void:
	DirAccess.make_dir_recursive_absolute("user://logs")
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(_CURSOR_DEBUG_LOG_PATH) else FileAccess.WRITE
	var f := FileAccess.open(_CURSOR_DEBUG_LOG_PATH, mode)
	if f == null:
		return
	if mode == FileAccess.READ_WRITE:
		f.seek_end()
	var enriched := data.duplicate()
	enriched["process_id"] = OS.get_process_id()
	enriched["is_server"] = is_server()
	enriched["peer_id"] = get_peer_id()
	var payload := {
		"sessionId": "debug-session",
		"runId": run_id,
		"hypothesisId": hypothesis_id,
		"location": location,
		"message": message,
		"data": enriched,
		"timestamp": Time.get_ticks_msec()
	}
	f.store_line(JSON.stringify(payload))
	f.close()

	#region agent log
	# 同步发送到 NDJSON ingest server（用于生成工作区 .cursor/debug.log）
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		req.queue_free()
	)
	req.request(_CURSOR_DEBUG_INGEST_ENDPOINT, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	#endregion
