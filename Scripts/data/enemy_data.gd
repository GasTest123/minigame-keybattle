extends Resource
class_name EnemyData

## 敌人数据 Resource 类
## 定义敌人的属性：HP、攻击力、移动速度等
## 外观由预制场景配置，数值由此资源配置

## 技能类型枚举
enum EnemySkillType {
	NONE,          # 无技能
	CHARGING,      # 冲锋技能
	SHOOTING,      # 射击技能
	EXPLODING,     # 自爆技能
	BOSS_SHOOTING  # Boss专属360度射击技能
}

## AI 行为类型枚举（仅影响“正常移动逻辑”，不影响技能行为与碰撞攻击机制）
enum EnemyAIType {
	MELEE,   # 近战追击（默认：保持原行为）
	RANGED,  # 保持距离
	ESCAPE,  # 受击逃离
	STILL    # 静止不动
}

@export var id: String = ""  # 敌人ID（用于网络同步识别）
@export var enemy_name: String = "默认敌人"
@export var description: String = ""

## 场景路径（指向预制场景）
@export var scene_path: String = ""

## 数值属性
@export var max_hp: int = 50  # 最大血量
@export var attack_damage: int = 5  # 攻击力
@export var move_speed: float = 300.0  # 移动速度
@export var attack_interval: float = 1.0  # 攻击间隔（秒）
@export var attack_range: float = 80.0  # 攻击范围

## AI 行为配置
## ai_config 字段由 ai_type 决定：
## - MELEE: 无参数
## - RANGED: minDistance/maxDistance/retreatAngleVariance/repositionCooldown
## - ESCAPE: fleeSpeed/fleeDurationmin/fleeDurationmax/retreatAngleVariance/repositionCooldown
## - STILL: can_flip
@export var ai_type: EnemyAIType = EnemyAIType.MELEE
@export var ai_config: Dictionary = {}

## 技能配置
@export var skill_type: EnemySkillType = EnemySkillType.NONE
@export var skill_config: Dictionary = {}  # 技能参数字典

## 动画名称映射（供行为脚本查找）
## 键: 逻辑动画名（walk/idle/attack/hurt/skill_prepare/skill_execute）
## 值: SpriteFrames 中实际的动画名
@export var animations: Dictionary = {
	"walk": "walk",
	"idle": "",
	"attack": "",
	"hurt": "",
	"skill_prepare": "",
	"skill_execute": ""
}

## 外观缩放（应用到场景根节点）
@export var scale: Vector2 = Vector2(1.0, 1.0)

## 死亡效果
@export var shake_on_death: bool = true  # 死亡时震动
@export var shake_duration: float = 0.2
@export var shake_amount: float = 8.0

## 击退抗性（0.0-1.0，0表示无抗性，1表示完全免疫击退）
@export_range(0.0, 1.0) var knockback_resistance: float = 0.0

## 金币掉落数量（死亡时掉落的gold数量，对masterkey无效）
@export var gold_drop_count: int = 1

## 每波成长点数（在基础值上额外增加的固定数值，配合波次成长率使用）
## 公式：(基础值 + 成长点数) * (1 + 波次成长率)
@export var hp_growth_per_wave: float = 0.0  # HP成长点数
@export var damage_growth_per_wave: float = 0.0  # 伤害成长点数

## 初始化函数（简化版，主要用于代码创建）
func _init(
	p_enemy_name: String = "默认敌人",
	p_max_hp: int = 50,
	p_attack_damage: int = 5,
	p_move_speed: float = 300.0,
	p_scene_path: String = ""
) -> void:
	enemy_name = p_enemy_name
	max_hp = p_max_hp
	attack_damage = p_attack_damage
	move_speed = p_move_speed
	scene_path = p_scene_path
