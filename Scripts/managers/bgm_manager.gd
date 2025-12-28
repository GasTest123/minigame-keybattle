extends Node

## BGM管理器
## 全局音乐管理，支持场景切换时不中断

@onready var audio_player: AudioStreamPlayer = AudioStreamPlayer.new()

## 当前播放的BGM名称
var current_bgm: String = ""

## BGM资源路径
const BGM_PATHS = {
	"title": "res://audio/BGM_title.mp3",
	"fight": "res://audio/BGM_fight.mp3",
	"title2": "res://audio/Keybattle_theme.mp3"
}

func _ready() -> void:
	# 添加AudioStreamPlayer到节点
	add_child(audio_player)
	
	# 设置为暂停时也继续播放（重要！）
	audio_player.process_mode = Node.PROCESS_MODE_ALWAYS
	
	# 设置为循环播放
	audio_player.finished.connect(_on_audio_finished)
	
	# 设置音量（可选）
	audio_player.volume_db = 0.0  # 0dB = 正常音量，-10dB = 较小声
	
	print("[BGMManager] 初始化完成（不受暂停影响）")

## 播放BGM
func play_bgm(bgm_name: String) -> void:
	# 如果已经在播放相同的BGM，不做处理
	if current_bgm == bgm_name and audio_player.playing:
		print("[BGMManager] 已在播放:", bgm_name)
		return
	
	# 检查BGM是否存在
	if not BGM_PATHS.has(bgm_name):
		push_error("[BGMManager] BGM不存在: ", bgm_name)
		return
	
	var bgm_path = BGM_PATHS[bgm_name]
	
	# 加载音频资源
	var audio_stream = load(bgm_path)
	if audio_stream == null:
		push_error("[BGMManager] 无法加载BGM文件: ", bgm_path)
		return
	
	# 设置音频流
	audio_player.stream = audio_stream
	
	# 播放
	audio_player.play()
	current_bgm = bgm_name
	
	print("[BGMManager] 开始播放BGM: ", bgm_name)

## 停止BGM
func stop_bgm() -> void:
	audio_player.stop()
	current_bgm = ""
	print("[BGMManager] 停止BGM")

## 暂停BGM（保留播放位置）
func pause_bgm() -> void:
	audio_player.stream_paused = true
	print("[BGMManager] 暂停BGM")

## 恢复BGM（从暂停位置继续播放）
func resume_bgm() -> void:
	audio_player.stream_paused = false
	print("[BGMManager] 恢复BGM")

## BGM是否暂停中
func is_paused() -> bool:
	return audio_player.stream_paused

## 设置音量
func set_volume(volume_db: float) -> void:
	audio_player.volume_db = volume_db
	print("[BGMManager] 设置音量: ", volume_db, "dB")

## 淡入淡出（可选功能）
func fade_to_bgm(bgm_name: String, fade_duration: float = 1.0) -> void:
	# 淡出当前BGM
	var tween = create_tween()
	tween.tween_property(audio_player, "volume_db", -80.0, fade_duration)
	await tween.finished
	
	# 播放新BGM
	play_bgm(bgm_name)
	
	# 淡入新BGM
	audio_player.volume_db = -80.0
	tween = create_tween()
	tween.tween_property(audio_player, "volume_db", 0.0, fade_duration)

## 音频播放完成（用于循环）
func _on_audio_finished() -> void:
	# 循环播放当前BGM
	if current_bgm != "":
		audio_player.play()
		print("[BGMManager] 循环播放: ", current_bgm)

## 获取当前播放的BGM
func get_current_bgm() -> String:
	return current_bgm

## 是否正在播放
func is_playing() -> bool:
	return audio_player.playing
