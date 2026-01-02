extends Control
class_name BossHPBar

## BOSS 血条组件
## 负责显示单个 BOSS/精英怪物的血量

## BOSS 类型对应的图片资源
const TEXTURE_MONITOR = preload("res://assets/UI/BOSSHP_ui/parrit-monitor.png")
const TEXTURE_ENT = preload("res://assets/UI/BOSSHP_ui/partrit-ent.png")

## 需要显示 BOSS 血条的敌人 ID 列表
const BOSS_ENEMY_IDS = ["ent", "monitor"]

## 引用节点
@onready var partrit: TextureRect = $Control/partrit
@onready var progress_bar: ProgressBar = $Control/partrit/ProgressBar

## 跟踪的敌人引用
## 注意：离线版敌人是 `Enemy`，联网版敌人是 `EnemyOnline`；
## 为了复用同一套 UI 组件，这里不强绑定具体脚本类型。
var tracked_enemy: Node = null
var enemy_id: String = ""

## 信号：敌人死亡时发出
signal enemy_died(bar: BossHPBar)

func _ready() -> void:
	# 默认隐藏
	visible = false

## 设置跟踪的敌人
func set_enemy(enemy: Node, id: String) -> void:
	tracked_enemy = enemy
	enemy_id = id
	
	if not tracked_enemy:
		visible = false
		return
	
	# 根据敌人类型设置图片
	_update_portrait_texture()
	
	# 连接敌人死亡信号
	if not tracked_enemy.enemy_killed.is_connected(_on_enemy_killed):
		tracked_enemy.enemy_killed.connect(_on_enemy_killed)
	
	# 初始化血条显示
	_update_hp_display()
	
	# 显示血条
	visible = true

## 根据敌人类型更新头像纹理
func _update_portrait_texture() -> void:
	if not partrit:
		return
	
	match enemy_id:
		"monitor":
			partrit.texture = TEXTURE_MONITOR
		"ent":
			partrit.texture = TEXTURE_ENT
		_:
			# 默认使用 monitor 图片
			partrit.texture = TEXTURE_MONITOR

## 更新血量显示
func _update_hp_display() -> void:
	if not progress_bar or not tracked_enemy:
		return
	
	# 兼容：Enemy / EnemyOnline
	var max_hp := 1
	var hp := 0
	if "max_enemyHP" in tracked_enemy:
		max_hp = int(tracked_enemy.max_enemyHP)
	if "enemyHP" in tracked_enemy:
		hp = int(tracked_enemy.enemyHP)
	progress_bar.max_value = max(1, max_hp)
	progress_bar.value = clamp(hp, 0, progress_bar.max_value)

## 每帧更新血量（因为敌人没有血量变化信号）
func _process(_delta: float) -> void:
	if not tracked_enemy or not is_instance_valid(tracked_enemy):
		# 敌人已被销毁，清理自己
		_cleanup()
		return
	
	_update_hp_display()

## 敌人死亡回调
func _on_enemy_killed(_enemy_ref: Node) -> void:
	_cleanup()

## 清理并通知父节点
func _cleanup() -> void:
	visible = false
	enemy_died.emit(self)
	queue_free()

## 静态方法：判断敌人是否需要显示 BOSS 血条
static func is_boss_enemy(id: String) -> bool:
	return id in BOSS_ENEMY_IDS
