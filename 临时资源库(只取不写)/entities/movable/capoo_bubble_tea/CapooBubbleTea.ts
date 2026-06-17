/**
 * ============================================================
 * 珍珠奶茶 Capoo (CapooBubbleTea)
 * ============================================================
 * 一种能攻击炮台的敌人类型，具有以下属性：
 * - 生命值：200
 * - 防御力：5
 * - 法术抗性：5
 * - 移动速度：每秒 0.6 格
 * 
 * 特殊能力：
 * - 当曼哈顿距离 2 格内有炮台时，停止移动并发动攻击
 * - 攻击时像机枪一样高速连续吐出珍珠（默认 10 颗）
 * - 攻击间隔 1.5 秒
 * - 攻击动画使用 20 帧精灵表
 */

import { Graphics, Rectangle, Sprite, Texture } from 'pixi.js';
import { Position, EnemyStats, EnemyType } from '../../../types';
import { Enemy } from '../Enemy';
import { AssetManager } from '../../../core/AssetManager';

/**
 * 珍珠奶茶 Capoo 状态
 */
enum BubbleTeaState {
    MOVING = 'moving',      // 移动状态
    ATTACKING = 'attacking', // 攻击状态
}

/**
 * 珍珠发射数据（用于回调通知 Game）
 */
export interface BubblePearlData {
    startPos: Position;
    targetPos: Position;
    targetId: string;
    damage: number;
    count: number; // 珍珠数量
}

/**
 * 珍珠奶茶 Capoo 默认属性
 */
const BUBBLETEA_STATS: EnemyStats = {
    health: 200,
    maxHealth: 200,
    attack: 15,  // 每颗珍珠的攻击力
    defense: 5,
    magicResist: 5,
    moveSpeed: 0.6, // 每秒移动0.6格
};

/**
 * 珍珠奶茶 Capoo 类
 */
export class CapooBubbleTea extends Enemy {
    /** 当前状态 */
    private bubbleState: BubbleTeaState = BubbleTeaState.MOVING;

    /** 精灵图（默认图） */
    private sprite: Sprite | null = null;

    /** 攻击动画帧纹理 */
    private attackFrameTextures: Texture[] = [];

    /** 当前动画帧 */
    private currentFrame: number = 0;

    /** 帧计时器 */
    private frameTimer: number = 0;

    /** 每帧持续时间（秒） */
    private readonly frameDuration: number = 0.05; // 20帧，总时长约1秒

    /** 攻击间隔（秒） */
    private readonly attackInterval: number = 1.5;

    /** 攻击冷却计时器 */
    private attackCooldown: number = 0;

    /** 每次攻击发射的珍珠数量 */
    public pearlCount: number = 10;

    /** 珍珠发射回调 */
    private onFirePearls: ((data: BubblePearlData) => void) | null = null;

    /** 当前攻击目标 */
    private currentTargetId: string | null = null;
    private currentTargetPos: Position | null = null;

    /** 回调是否已设置的标志（用于Game类判断） */
    public _pearlCallbackSet: boolean = false;

    /** 本次攻击已发射的珍珠数量 */
    private pearlsFired: number = 0;

    /** 珍珠连发间隔（秒） - 机枪式快速连发 */
    private readonly pearlFireInterval: number = 0.05; // 每 0.05 秒发射一颗

    /** 珍珠发射计时器 */
    private pearlFireTimer: number = 0;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param startPos 起始像素位置
     */
    constructor(id: string, startPos: Position) {
        const stats = { ...BUBBLETEA_STATS };
        super(id, EnemyType.CAPOO_BUBBLETEA, startPos, stats);

        // 设置攻击范围：曼哈顿距离 2（菱形）
        this.rangePattern = [
            [0, 0, 1, 0, 0],
            [0, 1, 1, 1, 0],
            [1, 1, 1, 1, 1],
            [0, 1, 1, 1, 0],
            [0, 0, 1, 0, 0],
        ];

        // 设置精灵图
        this.setupSprite();
    }

    /**
     * 设置精灵图
     */
    private setupSprite(): void {
        const assetManager = AssetManager.getInstance();

        // 获取默认图纹理
        const defaultTexture = assetManager.getTexture('capoo_bubbletea');
        if (defaultTexture) {
            this.sprite = new Sprite(defaultTexture);
            this.sprite.anchor.set(0.5);

            // 保持图片比例，适应格子大小（64x64）
            // 图片是横向稍宽的，所以按宽度缩放
            const maxSize = 60;
            const scale = Math.min(maxSize / defaultTexture.width, maxSize / defaultTexture.height);
            this.sprite.width = defaultTexture.width * scale;
            this.sprite.height = defaultTexture.height * scale;

            // 隐藏默认图形
            this.graphics.visible = false;

            // 添加精灵图
            this.container.addChild(this.sprite);
        }

        // 获取攻击动画精灵表
        const attackSprite = assetManager.getTexture('capoo_bubbletea_attack_sprite');
        if (attackSprite) {
            // 精灵表是水平排列的 20 帧
            const frameCount = 20;
            const frameWidth = attackSprite.width / frameCount;
            const frameHeight = attackSprite.height;

            for (let i = 0; i < frameCount; i++) {
                const frame = new Texture({
                    source: attackSprite.source,
                    frame: new Rectangle(i * frameWidth, 0, frameWidth, frameHeight),
                });
                this.attackFrameTextures.push(frame);
            }

            console.log(`[珍珠奶茶Capoo] 从精灵表加载了 ${this.attackFrameTextures.length} 帧攻击动画`);
        }
    }

    /**
     * 设置珍珠发射回调
     */
    public setOnFirePearls(callback: (data: BubblePearlData) => void): void {
        this.onFirePearls = callback;
    }

    /**
     * 更新（重写父类方法）
     * @param deltaTime 时间增量（秒）
     * @returns 是否到达终点
     */
    public update(deltaTime: number): boolean {
        if (!this.alive) return false;

        // 更新攻击冷却
        if (this.attackCooldown > 0) {
            this.attackCooldown -= deltaTime;
        }

        // 根据状态执行不同逻辑
        switch (this.bubbleState) {
            case BubbleTeaState.MOVING:
                return this.updateMoving(deltaTime);

            case BubbleTeaState.ATTACKING:
                this.updateAttacking(deltaTime);
                return false;
        }

        return false;
    }

    /**
     * 移动状态更新
     */
    private updateMoving(deltaTime: number): boolean {
        // 调用父类的移动逻辑
        const reachedEnd = super.update(deltaTime);

        // 移动时使用默认图
        if (this.sprite && this.attackFrameTextures.length > 0) {
            const defaultTexture = AssetManager.getInstance().getTexture('capoo_bubbletea');
            if (defaultTexture && this.sprite.texture !== defaultTexture) {
                this.sprite.texture = defaultTexture;
            }
        }

        return reachedEnd;
    }

    /**
     * 攻击状态更新
     */
    private updateAttacking(deltaTime: number): void {
        // 更新攻击动画帧
        this.frameTimer += deltaTime;

        if (this.frameTimer >= this.frameDuration) {
            this.frameTimer = 0;
            this.currentFrame++;

            // 更新帧纹理
            if (this.sprite && this.currentFrame < this.attackFrameTextures.length) {
                this.sprite.texture = this.attackFrameTextures[this.currentFrame];
            }
        }

        // 机枪式连续发射珍珠（在动画后半段发射，即第10帧之后）
        const halfwayFrame = Math.floor(this.attackFrameTextures.length / 2); // 第10帧
        this.pearlFireTimer += deltaTime;
        if (this.currentFrame >= halfwayFrame &&
            this.pearlFireTimer >= this.pearlFireInterval &&
            this.pearlsFired < this.pearlCount) {
            this.pearlFireTimer = 0;

            // 第一颗珍珠发射时播放音效
            if (this.pearlsFired === 0) {
                AssetManager.getInstance().playCapooBubbleTeaFireSound();
            }

            this.fireSinglePearl();
            this.pearlsFired++;
        }

        // 动画播放完毕 AND 珍珠发射完毕后才切换回移动状态
        const animationDone = this.currentFrame >= this.attackFrameTextures.length;
        const pearlsDone = this.pearlsFired >= this.pearlCount;

        if (animationDone && pearlsDone) {
            this.currentFrame = 0;
            this.pearlsFired = 0;
            this.pearlFireTimer = 0;

            // 切换回移动状态
            this.bubbleState = BubbleTeaState.MOVING;
            this.attackCooldown = this.attackInterval;

            console.log('[珍珠奶茶Capoo] 攻击完成，恢复移动');
        }
    }

    /**
     * 发射单颗珍珠
     */
    private fireSinglePearl(): void {
        if (!this.currentTargetId || !this.currentTargetPos || !this.onFirePearls) {
            return;
        }

        // 从嘴部位置发射（向右偏移）
        const startPos = {
            x: this.container.x + 15,
            y: this.container.y,
        };

        // 发射单颗珍珠
        this.onFirePearls({
            startPos,
            targetPos: this.currentTargetPos,
            targetId: this.currentTargetId,
            damage: this.stats.attack, // 使用基础攻击力
            count: 1, // 每次只发射一颗
        });
    }

    /**
     * 检查并尝试攻击范围内的炮台
     * @param towers 炮台信息列表
     * @returns 是否进入攻击状态
     */
    public tryAttack(towers: { id: string; tilePos: Position; pixelPos: Position; isAlive: boolean }[]): boolean {
        // 如果正在攻击或冷却中，不检查
        if (this.bubbleState === BubbleTeaState.ATTACKING || this.attackCooldown > 0) {
            return false;
        }

        // 查找攻击范围内的炮台
        for (const tower of towers) {
            if (!tower.isAlive) continue;

            // 使用继承的 isInRange 方法检查
            if (this.isInRange(tower.tilePos.x, tower.tilePos.y)) {
                // 进入攻击状态
                this.bubbleState = BubbleTeaState.ATTACKING;
                this.currentTargetId = tower.id;
                this.currentTargetPos = tower.pixelPos;
                this.currentFrame = 0;
                this.frameTimer = 0;
                this.pearlsFired = 0;
                this.pearlFireTimer = 0;

                console.log(`[珍珠奶茶Capoo] 发现目标 ${tower.id}，进入攻击状态`);
                return true;
            }
        }

        return false;
    }

    /**
     * 是否正在攻击
     */
    public isAttacking(): boolean {
        return this.bubbleState === BubbleTeaState.ATTACKING;
    }

    /**
     * 创建敌人图形（占位符）
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();
        this.drawPlaceholder(graphics);
        return graphics;
    }

    /**
     * 绘制占位符图形
     */
    private drawPlaceholder(graphics: Graphics): void {
        // 青色椭圆形（代表奶茶杯）
        graphics.ellipse(0, 0, 20, 25);
        graphics.fill({ color: 0x00bfff });

        // 棕色珍珠点缀
        graphics.circle(-8, 5, 4);
        graphics.circle(8, 5, 4);
        graphics.circle(0, 10, 4);
        graphics.fill({ color: 0x8B4513 });
    }
}
