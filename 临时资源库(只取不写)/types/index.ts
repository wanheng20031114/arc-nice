/**
 * ============================================================
 * 游戏类型定义文件
 * ============================================================
 * 包含所有游戏相关的 TypeScript 类型和接口定义
 */

// ============================================================
// 用户相关类型
// ============================================================

/**
 * 用户信息接口
 */
export interface User {
    /** 用户唯一ID */
    id: string;
    /** 用户名 */
    username: string;
    /** 账号创建时间 */
    createdAt: string;
}

/**
 * 登录请求参数
 */
export interface LoginRequest {
    username: string;
    password: string;
}

/**
 * 注册请求参数
 */
export interface RegisterRequest {
    username: string;
    password: string;
}

/**
 * 认证响应
 */
export interface AuthResponse {
    success: boolean;
    message?: string;
    user?: User;
    token?: string;
}

// ============================================================
// 地图相关类型
// ============================================================

/**
 * 格子类型枚举
 * GROUND - 地面格子（敌人可通行）
 * PLATFORM - 高台格子（可放置炮台，敌人不可通行）
 * RED_GATE - 红门（敌人出生点）
 * BLUE_GATE - 蓝门（我方基地，敌人终点）
 */
export enum TileType {
    GROUND = 'ground',
    PLATFORM = 'platform',
    RED_GATE = 'red_gate',
    BLUE_GATE = 'blue_gate',
    OBSTACLE = 'obstacle', // 障碍物（不可通行，不可放置）
}

/**
 * 地图格子字符定义（用于布局配置）
 */
export type TileChar = 'G' | 'P' | 'R' | 'B' | 'O' | '.';

/**
 * 地图字符到类型的映射表
 */
export const MAP_CHAR_TO_TYPE: Record<string, TileType | null> = {
    'G': TileType.GROUND,
    'P': TileType.PLATFORM,
    'R': TileType.RED_GATE,
    'B': TileType.BLUE_GATE,
    'O': TileType.OBSTACLE,
    '.': null, // 空白占位
};

/**
 * 地图格子接口
 */
export interface Tile {
    /** 格子X坐标（列） */
    x: number;
    /** 格子Y坐标（行） */
    y: number;
    /** 格子类型 */
    type: TileType;
    /** 是否有炮台 */
    hasTower: boolean;
}

/**
 * 地图配置接口
 */
export interface MapConfig {
    /** 地图宽度（格子数） */
    width: number;
    /** 地图高度（格子数） */
    height: number;
    /** 格子大小（像素） */
    tileSize: number;
    /** 地图数据（二维数组） */
    tiles: TileType[][];
    /** 红门位置列表 */
    redGates: Position[];
    /** 蓝门位置列表 */
    blueGates: Position[];
}

/**
 * 位置接口
 */
export interface Position {
    x: number;
    y: number;
}

// ============================================================
// 实体相关类型
// ============================================================

/**
 * 基础实体接口
 */
export interface Entity {
    /** 实体唯一ID */
    id: string;
    /** 实体位置（像素坐标） */
    position: Position;
    /** 是否存活 */
    isAlive: boolean;
}

/**
 * 炮台属性接口
 */
export interface TowerStats {
    /** 生命值 */
    health: number;
    /** 最大生命值 */
    maxHealth: number;
    /** 物理防御力 */
    defense: number;
    /** 法术抗性 */
    magicResist: number;
    /** 攻击力 */
    attack: number;
    /** 攻击速度（每秒攻击次数） */
    attackSpeed: number;
    /** 攻击范围模板（二维数组，1表示在范围内，0或中心标记表示不在） */
    rangePattern?: number[][];
}

/**
 * 炮台接口
 */
export interface Tower extends Entity {
    /** 炮台类型 */
    type: TowerType;
    /** 炮台属性 */
    stats: TowerStats;
    /** 所在格子位置 */
    tilePosition: Position;
    /** 攻击冷却计时器 */
    attackCooldown: number;
}

/**
 * 炮台类型枚举
 */
export enum TowerType {
    PROTOTYPE = 'prototype',     // 原型炮台
    FLAMETHROWER = 'flamethrower', // 喷火器
    LASER = 'laser',             // 激光塔
    ANTIAIRCRAFT = 'antiaircraft', // 防空塔
    GATLING = 'gatling',         // 加特林塔
    GUARD = 'guard',             // 近卫塔
}

/**
 * 敌人属性接口
 */
export interface EnemyStats {
    /** 生命值 */
    health: number;
    /** 最大生命值 */
    maxHealth: number;
    /** 攻击力 */
    attack: number;
    /** 物理防御力 */
    defense: number;
    /** 法术抗性 */
    magicResist: number;
    /** 移动速度（每秒格子数） */
    moveSpeed: number;
}

/**
 * 敌人接口
 */
export interface Enemy extends Entity {
    /** 敌人类型 */
    type: EnemyType;
    /** 敌人属性 */
    stats: EnemyStats;
    /** 当前行走路径 */
    path: Position[];
    /** 路径当前索引 */
    pathIndex: number;
}

/**
 * 敌人类型枚举
 */
export enum EnemyType {
    ZOMBIE = 'zombie', // 僵尸
    CAPOO_SWORDSMAN = 'capoo_swordsman', // Capoo 剑士
    CAPOO_BUBBLETEA = 'capoo_bubbletea', // Capoo 珍珠奶茶
    CAPOO_AK47 = 'capoo_ak47', // Capoo AK47
}

/**
 * 子弹接口
 */
export interface Projectile extends Entity {
    /** 伤害值 */
    damage: number;
    /** 移动速度（像素/秒） */
    speed: number;
    /** 目标敌人ID */
    targetId: string;
    /** 发射者ID（炮台） */
    ownerId: string;
}

// ============================================================
// 游戏状态相关类型
// ============================================================

/**
 * 游戏状态枚举
 */
export enum GameState {
    IDLE = 'idle',           // 空闲
    PLAYING = 'playing',     // 游戏中
    PAUSED = 'paused',       // 暂停
    VICTORY = 'victory',     // 胜利
    DEFEAT = 'defeat',       // 失败
}

/**
 * 波次信息接口
 */
export interface WaveInfo {
    /** 当前波次 */
    currentWave: number;
    /** 总波次数 */
    totalWaves: number;
    /** 当前波次敌人总数 */
    enemyCount: number;
    /** 当前波次剩余敌人数 */
    remainingEnemies: number;
}

/**
 * 游戏数据接口
 */
export interface GameData {
    /** 核心生命值 */
    coreHealth: number;
    /** 核心最大生命值 */
    maxCoreHealth: number;
    /** 游戏状态 */
    state: GameState;
    /** 波次信息 */
    wave: WaveInfo;
    /** 当前金币 */
    gold: number;
}

// ============================================================
// 寻路相关类型
// ============================================================

/**
 * 寻路节点接口
 */
export interface PathNode {
    /** 节点位置 */
    position: Position;
    /** G值：从起点到当前节点的代价 */
    g: number;
    /** H值：从当前节点到终点的估算代价 */
    h: number;
    /** F值：G + H */
    f: number;
    /** 父节点 */
    parent: PathNode | null;
}

// ============================================================
// 事件相关类型
// ============================================================

/**
 * 游戏事件类型
 */
export type GameEventType =
    | 'tower_placed'      // 炮台放置
    | 'tower_destroyed'   // 炮台被摧毁
    | 'enemy_spawned'     // 敌人生成
    | 'enemy_killed'      // 敌人被击杀
    | 'enemy_reached'     // 敌人到达蓝门
    | 'wave_start'        // 波次开始
    | 'wave_end'          // 波次结束
    | 'game_over'         // 游戏结束
    | 'projectile_hit';   // 子弹命中

/**
 * 游戏事件接口
 */
export interface GameEvent {
    type: GameEventType;
    data?: unknown;
}
