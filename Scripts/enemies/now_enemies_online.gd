extends Node2D

## 敌人生成器 Online
## 管理波次敌人的生成（联网模式）
## 使用 MultiplayerSpawner 自动同步敌人到所有客户端

@export var enemy_scene: PackedScene
@export var max_spawn_attempts: int = 20  # 最多尝试找位置的次数

## 新的波次系统 Online
var wave_system: Node = null
var enemy_spawner: Node = null

@onready var enemies_container: Node = $Enemies


func _ready() -> void:
	add_to_group("enemy_spawner")
	
	# 确保 Enemies 容器存在
	if not enemies_container:
		enemies_container = Node.new()
		enemies_container.name = "Enemies"
		add_child(enemies_container)
	
	# 创建新的波次系统
	wave_system = WaveSystemOnline.new()
	add_child(wave_system)
	wave_system.name = "WaveSystemOnline"
	wave_system.add_to_group("wave_manager")
	
	# 创建新的敌人生成器
	enemy_spawner = EnemySpawnerOnline.new()
	add_child(enemy_spawner)
	enemy_spawner.name = "EnemySpawnerOnline"
	
	# 配置生成器（fallback_enemy_scene 作为兜底，当敌人没有 scene_path 时使用）
	enemy_spawner.fallback_enemy_scene = enemy_scene
	enemy_spawner.max_spawn_attempts = max_spawn_attempts
	enemy_spawner.set_enemies_container(enemies_container)  # 设置 Enemies 容器
	
	# 连接系统
	wave_system.set_enemy_spawner(enemy_spawner)
	enemy_spawner.set_wave_system(wave_system)
	
	print("[now_enemies_online] 使用波次系统: ", wave_system.name)
	print("[now_enemies_online] MultiplayerSpawner 模式已启用")


## 获取波次管理器（供外部访问，保持兼容性）
func get_wave_manager():
	return wave_system


## 获取敌人生成器（供外部访问，保持兼容性）
func get_enemy_spawner():
	return enemy_spawner


## 获取 Enemies 容器
func get_enemies_container():
	return enemies_container
