/**
 * ============================================================
 * 激光塔单位
 * ============================================================
 * 高伤害远程攻击单位
 * 
 * 特性：
 * - 攻击速度慢（每 6 秒攻击一次）
 * - 高伤害激光攻击
 * - 精灵图动画系统
 * 
 * 动画状态：
 * - Idle（熄火）：范围内无敌人，帧 0
 * - Preheat（预热）：范围内有敌人，帧 1-5 顺序播放
 * - Firing（开火）：帧 6-7
 * 
 * 属性设计：
 * - 120 生命值
 * - 10 防御力
 * - 20 法术抗性
 * - 80 攻击力
 * - 1/6 攻击速度（每秒攻击次数）
 * - 5 攻击范围（直线）
 */

import { Graphics, Rectangle, Sprite, Texture } from 'pixi.js';
import { Position, TowerStats, TowerType } from '../../../types';
import { Tower } from '../Tower';
import { AssetManager } from '../../../core/AssetManager';

/**
 * 激光塔状态枚举
 */
enum LaserState {
    IDLE = 'idle',           // 熄火状态（无敌人）
    PREHEATING = 'preheating', // 预热状态
    FIRING = 'firing',       // 开火状态
}

/**
 * 激光塔攻击范围模板
 */
const LASER_RANGE_PATTERN = [
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
    [1, 1, 1, 1, 0, 1, 1, 1, 1],
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
    [0, 0, 0, 0, 1, 0, 0, 0, 0],
];

/**
 * 激光塔默认属性
 */
const LASER_STATS: TowerStats = {
    health: 1200,
    maxHealth: 1200,
    defense: 10,
    magicResist: 20,
    attack: 80,
    attackSpeed: 0.5,
    rangePattern: LASER_RANGE_PATTERN,
};

/**
 * 激光发射数据（用于回调通知 Game）
 */
export interface LaserFireData {
    startPos: Position;
    targetId: string;
    damage: number;
}

/**
 * 激光塔类
 */
export class LaserTower extends Tower {
    /** 当前动画状态 */
    private laserState: LaserState = LaserState.IDLE;

    /** 当前动画帧索引 */
    private currentFrame: number = 0;

    /** 帧动画计时器（秒） */
    private frameTimer: number = 0;

    /** 预热阶段每帧持续时间（秒） */
    private readonly preheatFrameDuration: number;

    /** 开火阶段每帧持续时间（秒） */
    private readonly firingFrameDuration: number = 0.5;

    /** 精灵图 */
    private sprite: Sprite | null = null;

    /** 动画帧纹理数组 */
    private frameTextures: Texture[] = [];

    /** 激光发射回调 */
    private onFireLaser: ((data: LaserFireData) => void) | null = null;

    /** 当前目标 ID（用于开火时） */
    private currentTargetId: string | null = null;

    /** 回调是否已设置的标志（用于Game类判断） */
    public _laserCallbackSet: boolean = false;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param tilePos 格子位置
     */
    constructor(id: string, tilePos: Position) {
        const stats = { ...LASER_STATS };
        super(id, TowerType.LASER, tilePos, stats);

        // 计算预热帧时长：攻击间隔 - 开火时长，分配给 5 帧
        const attackInterval = 1 / stats.attackSpeed; // 6 秒
        const firingDuration = 2 * this.firingFrameDuration; // 开火 2 帧
        this.preheatFrameDuration = (attackInterval - firingDuration) / 5; // 预热 5 帧

        // 初始化精灵图
        this.setupSprite();
    }

    /**
     * 设置精灵图
     * 从精灵表中切割 8 帧动画
     */
    private setupSprite(): void {
        const assetManager = AssetManager.getInstance();

        // 获取精灵表纹理
        const spriteSheet = assetManager.getTexture('laser_sprite');
        if (!spriteSheet) {
            console.warn('[激光塔] 未找到精灵表纹理 laser_sprite');
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

        console.log(`[激光塔] 从精灵表加载了 ${this.frameTextures.length} 帧动画`);
    }

    /**
     * 设置激光发射回调
     */
    public setOnFireLaser(callback: (data: LaserFireData) => void): void {
        this.onFireLaser = callback;
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

        // 更新动画状态
        this.updateAnimationState(deltaTime, hasEnemyInRange, target?.id || null, result);

        // 更新血条
        this.updateHealthBar();

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

        switch (this.laserState) {
            case LaserState.IDLE:
                // 无敌人时保持熄火状态
                if (hasEnemy) {
                    // 有敌人，开始预热
                    this.laserState = LaserState.PREHEATING;
                    this.currentFrame = 1;
                    this.frameTimer = 0;
                    this.currentTargetId = targetId;
                    this.updateFrame(1);
                    console.log('[激光塔] 检测到敌人，开始预热');
                }
                break;

            case LaserState.PREHEATING:
                // 预热阶段：帧 1-5
                if (!hasEnemy) {
                    // 敌人离开，回到熄火状态
                    this.laserState = LaserState.IDLE;
                    this.updateFrame(0);
                    this.frameTimer = 0;
                    console.log('[激光塔] 敌人离开，回到熄火状态');
                } else if (this.frameTimer >= this.preheatFrameDuration) {
                    this.frameTimer = 0;
                    if (this.currentFrame < 5) {
                        // 继续预热动画
                        this.currentFrame++;
                        this.updateFrame(this.currentFrame);
                    } else {
                        // 预热完成，进入开火状态
                        this.laserState = LaserState.FIRING;
                        this.currentFrame = 6;
                        this.updateFrame(6);
                        this.currentTargetId = targetId; // 更新目标
                        console.log('[激光塔] 预热完成，开火！');
                    }
                }
                break;

            case LaserState.FIRING:
                // 开火阶段：帧 6-7
                if (this.frameTimer >= this.firingFrameDuration) {
                    this.frameTimer = 0;
                    if (this.currentFrame === 6) {
                        // 切换到帧 7
                        this.currentFrame = 7;
                        this.updateFrame(7);

                        // 在帧 7 时触发实际伤害
                        if (this.currentTargetId && this.onFireLaser) {
                            this.onFireLaser({
                                startPos: {//wh备注，这里我们要调整到炮口位置发出激光
                                    x: this.pixelPosition.x + 20,
                                    y: this.pixelPosition.y - 12,
                                },
                                targetId: this.currentTargetId,
                                damage: this.stats.attack,
                            });
                            result.shouldFire = true;
                            result.targetId = this.currentTargetId;
                        }
                    } else {
                        // 开火完成，检查是否继续循环
                        if (hasEnemy) {
                            // 还有敌人，继续预热
                            this.laserState = LaserState.PREHEATING;
                            this.currentFrame = 1;
                            this.updateFrame(1);
                            this.currentTargetId = targetId;
                            console.log('[激光塔] 继续循环，开始预热');
                        } else {
                            // 无敌人，回到熄火
                            this.laserState = LaserState.IDLE;
                            this.updateFrame(0);
                            console.log('[激光塔] 无敌人，回到熄火状态');
                        }
                    }
                }
                break;
        }
    }

    /**
     * 获取炮台名称
     */
    public getName(): string {
        return '激光塔';
    }

    /**
     * 创建炮台图形（抽象方法实现）
     * 激光塔使用精灵图，此方法只创建占位符
     */
    protected createGraphics(): Graphics {
        // 激光塔使用精灵图而非图形
        // 创建一个新的 Graphics 对象作为占位符（会被精灵图覆盖）
        const graphics = new Graphics();
        graphics.rect(-this.tileSize / 2, -this.tileSize / 2, this.tileSize, this.tileSize);
        graphics.fill({ color: 0xff3333, alpha: 0.5 });
        return graphics;
    }
}
