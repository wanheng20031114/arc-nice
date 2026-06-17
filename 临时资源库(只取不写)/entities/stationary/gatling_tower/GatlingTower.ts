/**
 * ============================================================
 * 加特林塔单位
 * ============================================================
 * 高速连续射击单位
 * 
 * 特性：
 * - 高速连续发射子弹
 * - 较大攻击范围
 * - 精灵图动画系统（6帧）
 * 
 * 动画状态：
 * - Idle（待机）：帧 0，范围内无敌人
 * - Firing（开火）：帧 1-5 快速循环播放
 * 
 * 属性设计：
 * - 150 生命值
 * - 5 防御力
 * - 5 法术抗性
 * - 8 攻击力（每发子弹）
 * - 10 攻击速度（每秒发射 10 发子弹）
 */

import { Graphics, Rectangle, Sprite, Texture } from 'pixi.js';
import { Position, TowerStats, TowerType } from '../../../types';
import { Tower } from '../Tower';
import { AssetManager } from '../../../core/AssetManager';

/**
 * 加特林塔状态枚举
 */
enum GatlingState {
    IDLE = 'idle',
    FIRING = 'firing',
}

/**
 * 加特林塔攻击范围模板（9x9 较大范围）
 */
const GATLING_RANGE_PATTERN = [
    [0, 0, 0, 1, 1, 1, 0, 0, 0],
    [0, 0, 1, 1, 1, 1, 1, 0, 0],
    [0, 1, 1, 1, 1, 1, 1, 1, 0],
    [1, 1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1, 1],
    [0, 1, 1, 1, 1, 1, 1, 1, 0],
    [0, 0, 1, 1, 1, 1, 1, 0, 0],
    [0, 0, 0, 1, 1, 1, 0, 0, 0],
];

/**
 * 加特林塔默认属性
 */
const GATLING_STATS: TowerStats = {
    health: 150,
    maxHealth: 150,
    defense: 5,
    magicResist: 5,
    attack: 14,            // 每发子弹伤害
    attackSpeed: 10,      // 每秒发射 10 发子弹
    rangePattern: GATLING_RANGE_PATTERN,
};

/**
 * 加特林塔类
 */
export class GatlingTower extends Tower {
    /** 当前动画状态 */
    private gatlingState: GatlingState = GatlingState.IDLE;

    /** 当前动画帧索引 */
    private currentFrame: number = 0;

    /** 帧动画计时器（秒） */
    private frameTimer: number = 0;

    /** 开火阶段每帧持续时间（秒） - 快速循环 */
    private readonly firingFrameDuration: number = 0.05;

    /** 射击冷却计时器 */
    private shootCooldown: number = 0;

    /** 精灵图 */
    private sprite: Sprite | null = null;

    /** 动画帧纹理数组 */
    private frameTextures: Texture[] = [];

    /** 当前目标 ID */
    private currentTargetId: string | null = null;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param tilePos 格子位置
     */
    constructor(id: string, tilePos: Position) {
        const stats = { ...GATLING_STATS };
        super(id, TowerType.GATLING, tilePos, stats);

        // 初始化精灵图
        this.setupSprite();
    }

    /**
     * 设置精灵图
     * 从精灵表中切割 6 帧动画
     */
    private setupSprite(): void {
        const assetManager = AssetManager.getInstance();

        const spriteSheet = assetManager.getTexture('gatling_sprite');
        if (!spriteSheet) {
            console.warn('[加特林塔] 未找到精灵表纹理 gatling_sprite');
            return;
        }

        // 精灵表参数（6 帧水平排列）
        const frameCount = 6;
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

        console.log(`[加特林塔] 从精灵表加载了 ${this.frameTextures.length} 帧动画`);
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

        // 更新射击冷却
        this.shootCooldown -= deltaTime;

        // 检查范围内是否有敌人
        const target = this.findTarget(enemies);
        const hasEnemyInRange = target !== null;

        if (target) {
            this.currentTargetId = target.id;
        }

        // 更新动画状态
        this.updateAnimationState(deltaTime, hasEnemyInRange);

        // 如果有敌人且冷却完成，发射子弹
        if (hasEnemyInRange && this.currentTargetId && this.shootCooldown <= 0) {
            result.shouldFire = true;
            result.targetId = this.currentTargetId;
            this.shootCooldown = 1 / this.stats.attackSpeed; // 重置冷却
        }

        return result;
    }

    /**
     * 更新动画状态机
     */
    private updateAnimationState(deltaTime: number, hasEnemy: boolean): void {
        this.frameTimer += deltaTime;

        switch (this.gatlingState) {
            case GatlingState.IDLE:
                if (hasEnemy) {
                    // 有敌人，开始开火
                    this.gatlingState = GatlingState.FIRING;
                    this.currentFrame = 1;
                    this.frameTimer = 0;
                    this.updateFrame(1);
                }
                break;

            case GatlingState.FIRING:
                if (!hasEnemy) {
                    // 敌人离开，回到待机状态
                    this.gatlingState = GatlingState.IDLE;
                    this.updateFrame(0);
                    this.frameTimer = 0;
                } else if (this.frameTimer >= this.firingFrameDuration) {
                    // 快速循环开火动画 (帧 1-5)
                    this.frameTimer = 0;
                    this.currentFrame++;
                    if (this.currentFrame > 5) {
                        this.currentFrame = 1; // 循环回到帧 1
                    }
                    this.updateFrame(this.currentFrame);
                }
                break;
        }
    }

    /**
     * 获取炮台名称
     */
    public getName(): string {
        return '加特林塔';
    }

    /**
     * 创建炮台图形（抽象方法实现）
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();
        graphics.rect(-this.tileSize / 2, -this.tileSize / 2, this.tileSize, this.tileSize);
        graphics.fill({ color: 0x4a4a4a, alpha: 0.5 });
        return graphics;
    }
}
