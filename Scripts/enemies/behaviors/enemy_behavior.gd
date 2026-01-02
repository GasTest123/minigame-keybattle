extends Node
class_name EnemyBehavior

## 敌人技能行为基类
## 所有技能行为都应该继承此类
## 支持 Enemy（单机模式）和 EnemyOnline（联网模式）

## 敌人引用（兼容 Enemy 和 EnemyOnline）
var enemy: CharacterBody2D = null

## 技能配置
var config: Dictionary = {}

## 是否激活
var is_active: bool = true

## 初始化技能行为
func initialize(enemy_ref: CharacterBody2D, skill_config: Dictionary) -> void:
	enemy = enemy_ref
	config = skill_config
	_on_initialize()

## 子类可以重写的初始化方法
func _on_initialize() -> void:
	pass

## 每帧更新（在Enemy的_process中调用）
func update_behavior(delta: float) -> void:
	if not is_active or not enemy or enemy.is_dead:
		return
	_on_update(delta)

## 物理更新（在Enemy的_physics_process中调用）
func update_physics(delta: float) -> void:
	if not is_active or not enemy or enemy.is_dead:
		return
	_on_physics_update(delta)

## 子类需要重写的方法
func _on_update(_delta: float) -> void:
	pass

func _on_physics_update(_delta: float) -> void:
	pass

## 获取玩家引用
func get_player() -> Node:
	if not enemy:
		return null
	if not is_instance_valid(enemy.target):
		return null
	return enemy.target

## 获取到玩家的距离
func get_distance_to_player() -> float:
	var player = get_player()
	if not player or not enemy:
		return INF
	return enemy.global_position.distance_to(player.global_position)

## 获取到玩家的方向
func get_direction_to_player() -> Vector2:
	var player = get_player()
	if not player or not enemy:
		return Vector2.ZERO
	return (player.global_position - enemy.global_position).normalized()
