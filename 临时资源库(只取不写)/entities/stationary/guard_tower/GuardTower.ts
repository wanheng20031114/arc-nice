/**
 * ============================================================
 * 近卫塔单位
 * ============================================================
 * 辅助型防御塔，提供防御光环和自我治疗
 * 
 * 特性：
 * - 可放置在高台或地面，不阻挡敌人
 * - 十字形攻击范围（自身+上下左右）
 * - 高物理防御(50)和法术防御(40)
 * - 为周围4格友方单位提供 +10 物理防御光环（不可叠加）
 * - 技力条系统：满技力时自动回复 100 HP
 * 
 * 动画状态：
 * - Idle（待机）：帧 0
 * - Attacking（攻击）：帧 1-4 快速循环
 * 
 * 属性设计：
 * - 500 生命值
 * - 50 物理防御
 * - 40 法术抗性
 * - 15 攻击力
 * - 1 攻击速度
 * - 10 满技力
 * - 1/秒 技力回复
 * - 100 技能治疗量
 */

import { Graphics, Rectangle, Sprite, Texture } from 'pixi.js';
import { Position, TowerStats, TowerType } from '../../../types';
import { Tower } from '../Tower';
import { AssetManager } from '../../../core/AssetManager';

/**
 * 近卫塔状态枚举
 */
enum GuardState {
    IDLE = 'idle',
    ATTACKING = 'attacking',
}

/**
 * 近卫塔攻击范围模板（十字形：自身+上下左右）
 */
const GUARD_RANGE_PATTERN = [
    [0, 1, 0],
    [1, 1, 1],
    [0, 1, 0],
];

/**
 * 近卫塔默认属性
 */
const GUARD_STATS: TowerStats = {
    health: 500,
    maxHealth: 500,
    defense: 50,
    magicResist: 40,
    attack: 15,
    attackSpeed: 1,  // 每秒攻击1次
    rangePattern: GUARD_RANGE_PATTERN,
};

/**
 * 近卫塔配置常量
 */
const GUARD_CONFIG = {
    maxSp: 10,           // 满技力
    spRegenRate: 1,      // 每秒技力回复
    healAmount: 100,     // 技能治疗量
    auraBonus: 10,       // 光环防御加成（用于显示）
};

/**
 * 近卫塔类
 */
export class GuardTower extends Tower {
    /** 当前动画状态 */
    private guardState: GuardState = GuardState.IDLE;

    /** 当前动画帧索引 */
    private currentFrame: number = 0;

    /** 帧动画计时器（秒） */
    private frameTimer: number = 0;

    /** 攻击阶段每帧持续时间（秒） */
    private readonly attackFrameDuration: number = 0.1;

    /** 精灵图 */
    private sprite: Sprite | null = null;

    /** 动画帧纹理数组 */
    private frameTextures: Texture[] = [];

    /** 当前技力 */
    private sp: number = 0;

    /** 满技力 */
    private maxSp: number = GUARD_CONFIG.maxSp;

    /** 技力回复速率（每秒） */
    private spRegenRate: number = GUARD_CONFIG.spRegenRate;

    /** 技能治疗量 */
    private healAmount: number = GUARD_CONFIG.healAmount;

    /** 技力条图形 */
    private spBar: Graphics;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param tilePos 格子位置
     */
    constructor(id: string, tilePos: Position) {
        const stats = { ...GUARD_STATS };
        super(id, TowerType.GUARD, tilePos, stats);

        // 初始化精灵图
        this.setupSprite();

        // 创建技力条
        this.spBar = this.createSpBar();
    }

    /**
     * 设置精灵图
     * 从精灵表中切割 5 帧动画
     */
    private setupSprite(): void {
        const assetManager = AssetManager.getInstance();

        const spriteSheet = assetManager.getTexture('guard_sprite');
        if (!spriteSheet) {
            console.warn('[近卫塔] 未找到精灵表纹理 guard_sprite');
            return;
        }

        // 精灵表参数（5 帧水平排列）
        const frameCount = 5;
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

        console.log(`[近卫塔] 从精灵表加载了 ${this.frameTextures.length} 帧动画`);
    }

    /**
     * 创建技力条
     */
    private createSpBar(): Graphics {
        const bar = new Graphics();
        this.updateSpBar(bar);
        // 技力条位置：在血条下方
        bar.x = this.pixelPosition.x;
        bar.y = this.pixelPosition.y;
        return bar;
    }

    /**
     * 更新技力条显示
     */
    private updateSpBar(bar?: Graphics): void {
        const spBar = bar || this.spBar;
        spBar.clear();

        const barWidth = 50;
        const barHeight = 3;
        const spPercent = this.sp / this.maxSp;

        // 技力条 Y 偏移：在血条下方
        const barY = -this.tileSize / 2 + 7;

        // 背景（深蓝色）
        spBar.rect(-barWidth / 2, barY, barWidth, barHeight);
        spBar.fill({ color: 0x1a1a3e });

        // 技力值（淡蓝色）
        spBar.rect(-barWidth / 2, barY, barWidth * spPercent, barHeight);
        spBar.fill({ color: 0x3498db });

        // 边框
        spBar.rect(-barWidth / 2, barY, barWidth, barHeight);
        spBar.stroke({ color: 0x5dade2, width: 1 });
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

        // 更新技力
        this.updateSp(deltaTime);

        // 检查范围内是否有敌人
        const target = this.findTarget(enemies);
        const hasEnemyInRange = target !== null;

        // 更新动画状态
        this.updateAnimationState(deltaTime, hasEnemyInRange);

        // 更新攻击冷却
        if (this.attackCooldown > 0) {
            this.attackCooldown -= deltaTime;
        }

        // 如果有敌人且冷却完成，准备攻击
        if (hasEnemyInRange && target && this.attackCooldown <= 0) {
            this.attackCooldown = 1 / this.stats.attackSpeed;
            result.shouldFire = true;
            result.targetId = target.id;
        }

        return result;
    }

    /**
     * 更新技力
     */
    private updateSp(deltaTime: number): void {
        if (this.sp >= this.maxSp) {
            // 技力已满，释放技能
            this.useSkill();
        } else {
            // 回复技力
            this.sp += this.spRegenRate * deltaTime;
            if (this.sp > this.maxSp) {
                this.sp = this.maxSp;
            }
            this.updateSpBar();
        }
    }

    /**
     * 使用技能：回复生命值
     */
    private useSkill(): void {
        const oldHealth = this.stats.health;
        this.stats.health = Math.min(this.stats.health + this.healAmount, this.stats.maxHealth);
        const actualHeal = this.stats.health - oldHealth;

        if (actualHeal > 0) {
            console.log(`[近卫塔] 技能释放！回复 ${actualHeal} 点生命值`);
        }

        // 重置技力
        this.sp = 0;
        this.updateSpBar();
        this.updateHealthBar();
    }

    /**
     * 更新动画状态机
     */
    private updateAnimationState(deltaTime: number, hasEnemy: boolean): void {
        this.frameTimer += deltaTime;

        switch (this.guardState) {
            case GuardState.IDLE:
                if (hasEnemy) {
                    // 有敌人，开始攻击
                    this.guardState = GuardState.ATTACKING;
                    this.currentFrame = 1;
                    this.frameTimer = 0;
                    this.updateFrame(1);
                }
                break;

            case GuardState.ATTACKING:
                if (!hasEnemy) {
                    // 敌人离开，回到待机状态
                    this.guardState = GuardState.IDLE;
                    this.updateFrame(0);
                    this.frameTimer = 0;
                } else if (this.frameTimer >= this.attackFrameDuration) {
                    // 快速循环攻击动画 (帧 1-4)
                    this.frameTimer = 0;
                    this.currentFrame++;
                    if (this.currentFrame > 4) {
                        this.currentFrame = 1; // 循环回到帧 1
                    }
                    this.updateFrame(this.currentFrame);
                }
                break;
        }
    }

    /**
     * 获取技力条容器
     */
    public getSpBarContainer(): Graphics {
        return this.spBar;
    }

    /**
     * 获取周围4格坐标（用于光环效果）
     */
    public getAuraAffectedTiles(): Position[] {
        const pos = this.tilePosition;
        return [
            { x: pos.x, y: pos.y - 1 },  // 上
            { x: pos.x, y: pos.y + 1 },  // 下
            { x: pos.x - 1, y: pos.y },  // 左
            { x: pos.x + 1, y: pos.y },  // 右
        ];
    }

    /**
     * 获取光环加成值
     */
    public getAuraBonus(): number {
        return GUARD_CONFIG.auraBonus;
    }

    /**
     * 获取炮台名称
     */
    public getName(): string {
        return '近卫塔';
    }

    /**
     * 创建炮台图形（抽象方法实现）
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();
        // 仅作为一个底座占位符，主要视觉由精灵图提供
        return graphics;
    }

    /**
     * 重写销毁方法
     */
    public destroy(): void {
        this.spBar.destroy();
        super.destroy();
    }
}
