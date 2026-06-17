/**
 * ============================================================
 * 防空塔单位
 * ============================================================
 * 远程 AOE 攻击单位，近处有盲区
 * 
 * 特性：
 * - 攻击远处敌人，近处无法攻击（环形攻击范围）
 * - 命中后造成分层 AOE 伤害
 * - 精灵图动画系统（8帧）
 * 
 * 动画状态：
 * - Idle（待机）：帧 0，范围内无敌人
 * - Preheating（预热）：帧 1-6，检测到敌人后预热
 * - Firing（开火）：帧 7，开火瞬间
 * 
 * 属性设计：
 * - 100 生命值
 * - 10 防御力
 * - 15 法术抗性
 * - 50 基础伤害
 * - 3 秒攻击间隔
 */

import { Graphics, Rectangle, Sprite, Texture } from 'pixi.js';
import { Position, TowerStats, TowerType } from '../../../types';
import { Tower } from '../Tower';
import { AssetManager } from '../../../core/AssetManager';

/**
 * 防空塔状态枚举
 */
enum AntiaircraftState {
    IDLE = 'idle',
    PREHEATING = 'preheating',
    FIRING = 'firing',
}

/**
 * 分层伤害配置
 */
export interface DamageLayer {
    /** 半径（像素） */
    radius: number;
    /** 伤害百分比 (1.0 = 100%) */
    damagePercent: number;
}

/**
 * 防空塔开火数据（用于回调通知 Game）
 */
export interface AntiaircraftFireData {
    /** 爆炸中心位置 */
    position: Position;
    /** 基础伤害 */
    baseDamage: number;
    /** 分层伤害配置 */
    layers: DamageLayer[];
}

/**
 * 防空塔攻击范围模板（11x11 环形，中心 5x5 盲区）
 */
const ANTIAIRCRAFT_RANGE_PATTERN = [
    [0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0],
    [0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0],
    [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
    [1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1],
    [1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1],
    [1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1],
    [1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1],
    [1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1],
    [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
    [0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0],
    [0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0],
];

/**
 * 默认分层伤害配置
 */
const DEFAULT_EXPLOSION_LAYERS: DamageLayer[] = [
    { radius: 32, damagePercent: 1.0 },   // 中心 1 格：100%
    { radius: 64, damagePercent: 0.6 },   // 中层 2 格：60%
    { radius: 96, damagePercent: 0.3 },   // 外层 3 格：30%
];

/**
 * 防空塔默认属性
 */
const ANTIAIRCRAFT_STATS: TowerStats = {
    health: 100,
    maxHealth: 100,
    defense: 10,
    magicResist: 15,
    attack: 50,
    attackSpeed: 1 / 3,  // 3 秒攻击一次
    rangePattern: ANTIAIRCRAFT_RANGE_PATTERN,
};

/**
 * 防空塔类
 */
export class AntiaircraftTower extends Tower {
    /** 当前动画状态 */
    private aaState: AntiaircraftState = AntiaircraftState.IDLE;

    /** 当前动画帧索引 */
    private currentFrame: number = 0;

    /** 帧动画计时器（秒） */
    private frameTimer: number = 0;

    /** 预热阶段每帧持续时间（秒） */
    private readonly preheatFrameDuration: number;

    /** 开火阶段持续时间（秒） */
    private readonly firingDuration: number = 0.3;

    /** 精灵图 */
    private sprite: Sprite | null = null;

    /** 动画帧纹理数组 */
    private frameTextures: Texture[] = [];

    /** 开火回调 */
    private onFire: ((data: AntiaircraftFireData) => void) | null = null;

    /** 当前目标位置（用于爆炸） */
    private currentTargetPos: Position | null = null;

    /** 回调是否已设置的标志 */
    public _antiaircraftCallbackSet: boolean = false;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param tilePos 格子位置
     */
    constructor(id: string, tilePos: Position) {
        const stats = { ...ANTIAIRCRAFT_STATS };
        super(id, TowerType.ANTIAIRCRAFT, tilePos, stats);

        // 计算预热帧时长：攻击间隔 - 开火时长，分配给 6 帧
        const attackInterval = 1 / stats.attackSpeed; // 3 秒
        this.preheatFrameDuration = (attackInterval - this.firingDuration) / 6;

        // 初始化精灵图
        this.setupSprite();
    }

    /**
     * 设置精灵图
     * 从精灵表中切割 8 帧动画
     */
    private setupSprite(): void {
        const assetManager = AssetManager.getInstance();

        const spriteSheet = assetManager.getTexture('antiaircraft_sprite');
        if (!spriteSheet) {
            console.warn('[防空塔] 未找到精灵表纹理 antiaircraft_sprite');
            return;
        }

        // 精灵表参数（8 帧水平排列）
        const frameCount = 8;
        const frameWidth = spriteSheet.width / frameCount;
        const frameHeight = spriteSheet.height;

        // 从精灵表中切割每一帧
        for (let i = 0; i < frameCount; i++) {
            const frame = new Texture({
                source: spriteSheet.source,
                frame: new Rectangle(i * frameWidth, 0, frameWidth, frameHeight),
            });
            this.frameTextures.push(frame);
        }

        // 使用第一帧创建精灵
        if (this.frameTextures.length > 0) {
            this.sprite = new Sprite(this.frameTextures[0]);
            this.sprite.anchor.set(0.5);
            this.sprite.width = this.tileSize;
            this.sprite.height = this.tileSize;
            this.container.addChildAt(this.sprite, 0);

            // 隐藏默认图形
            this.graphics.visible = false;
        }

        console.log(`[防空塔] 从精灵表加载了 ${this.frameTextures.length} 帧动画`);
    }

    /**
     * 设置开火回调
     */
    public setOnFire(callback: (data: AntiaircraftFireData) => void): void {
        this.onFire = callback;
    }

    /**
     * 更新帧动画
     */
    private updateFrame(frameIndex: number): void {
        this.currentFrame = frameIndex;
        if (this.sprite && this.frameTextures[frameIndex]) {
            this.sprite.texture = this.frameTextures[frameIndex];
        }
    }

    /**
     * 重写更新方法
     */
    public update(deltaTime: number, enemies: { id: string; position: Position; isAlive: boolean }[]): {
        shouldFire: boolean;
        targetId: string | null;
    } {
        const result: { shouldFire: boolean; targetId: string | null } = { shouldFire: false, targetId: null };

        if (!this.alive) return result;

        // 检查范围内是否有敌人
        const target = this.findTarget(enemies);
        const hasEnemyInRange = target !== null;

        if (target) {
            this.currentTargetPos = target.position;
        }

        // 更新动画状态
        this.updateAnimationState(deltaTime, hasEnemyInRange, target?.id || null, result);

        return result;
    }

    /**
     * 更新动画状态机
     */
    private updateAnimationState(
        deltaTime: number,
        hasEnemy: boolean,
        targetId: string | null,
        result: { shouldFire: boolean; targetId: string | null }
    ): void {
        this.frameTimer += deltaTime;

        switch (this.aaState) {
            case AntiaircraftState.IDLE:
                if (hasEnemy) {
                    // 有敌人，开始预热
                    this.aaState = AntiaircraftState.PREHEATING;
                    this.currentFrame = 1;
                    this.frameTimer = 0;
                    this.updateFrame(1);
                    console.log('[防空塔] 检测到敌人，开始预热');
                }
                break;

            case AntiaircraftState.PREHEATING:
                if (!hasEnemy) {
                    // 敌人离开，回到待机状态
                    this.aaState = AntiaircraftState.IDLE;
                    this.updateFrame(0);
                    this.frameTimer = 0;
                    console.log('[防空塔] 敌人离开，回到待机状态');
                } else if (this.frameTimer >= this.preheatFrameDuration) {
                    this.frameTimer = 0;
                    if (this.currentFrame < 6) {
                        // 继续预热动画 (帧 1-6)
                        this.currentFrame++;
                        this.updateFrame(this.currentFrame);
                    } else {
                        // 预热完成，进入开火状态
                        this.aaState = AntiaircraftState.FIRING;
                        this.currentFrame = 7;
                        this.updateFrame(7);
                        console.log('[防空塔] 预热完成，开火！');

                        // 触发开火
                        if (this.currentTargetPos && this.onFire) {
                            this.onFire({
                                position: { ...this.currentTargetPos },
                                baseDamage: this.stats.attack,
                                layers: [...DEFAULT_EXPLOSION_LAYERS],
                            });
                            result.shouldFire = true;
                            result.targetId = targetId;
                        }
                    }
                }
                break;

            case AntiaircraftState.FIRING:
                if (this.frameTimer >= this.firingDuration) {
                    this.frameTimer = 0;
                    // 开火完成，检查是否继续循环
                    if (hasEnemy) {
                        // 还有敌人，继续预热
                        this.aaState = AntiaircraftState.PREHEATING;
                        this.currentFrame = 1;
                        this.updateFrame(1);
                        console.log('[防空塔] 继续循环，开始预热');
                    } else {
                        // 无敌人，回到待机
                        this.aaState = AntiaircraftState.IDLE;
                        this.updateFrame(0);
                        console.log('[防空塔] 无敌人，回到待机状态');
                    }
                }
                break;
        }
    }

    /**
     * 获取炮台名称
     */
    public getName(): string {
        return '防空塔';
    }

    /**
     * 创建炮台图形（抽象方法实现）
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();
        graphics.rect(-this.tileSize / 2, -this.tileSize / 2, this.tileSize, this.tileSize);
        graphics.fill({ color: 0x8b4513, alpha: 0.5 });
        return graphics;
    }
}
