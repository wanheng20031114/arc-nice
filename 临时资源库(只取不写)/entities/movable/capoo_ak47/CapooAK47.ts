/**
* ============================================================
* AK47 Capoo (CapooAK47)
* ============================================================
* 手持 AK47 的 Capoo 敌人，具有以下属性：
* - 生命值：250
* - 攻击力：30（每发子弹伤害）
* - 防御力：8
* - 法术抗性：5
* - 移动速度：每秒 0.5 格
* 
* 特殊能力：
* - 攻击范围：曼哈顿距离 3
* - 每次攻击发射 20 发子弹（可配置）
* - 攻击持续 2 秒（可配置）
* - 攻击冷却 4 秒（可配置）
* - 3 帧精灵表循环播放攻击动画
*/

import { Graphics, Rectangle, Sprite, Texture } from 'pixi.js';
import { Position, EnemyStats, EnemyType } from '../../../types';
import { Enemy } from '../Enemy';
import { AssetManager } from '../../../core/AssetManager';

/**
 * AK47 Capoo 状态
 */
enum AK47State {
    MOVING = 'moving',      // 移动状态
    ATTACKING = 'attacking', // 攻击状态
}

/**
 * 子弹发射数据（用于回调通知 Game）
 */
export interface AK47BulletData {
    startPos: Position;
    targetPos: Position;
    targetId: string;
    damage: number;
    count: number; // 子弹数量
}

/**
 * AK47 Capoo 默认属性
 */
const AK47_STATS: EnemyStats = {
    health: 100,
    maxHealth: 100,
    attack: 25,  // 每发子弹伤害
    defense: 0,
    magicResist: 0,
    moveSpeed: 0.5, // 每秒移动0.5格
};

/**
 * AK47 Capoo 类
 */
export class CapooAK47 extends Enemy {
    /** 当前状态 */
    private ak47State: AK47State = AK47State.MOVING;

    /** 精灵图（默认图） */
    private sprite: Sprite | null = null;

    /** 攻击动画帧纹理 */
    private attackFrameTextures: Texture[] = [];

    /** 当前动画帧 */
    private currentFrame: number = 0;

    /** 帧计时器 */
    private frameTimer: number = 0;

    /** 每帧持续时间（秒）- 3帧动画循环 */
    private readonly frameDuration: number = 0.1;

    /** 攻击间隔（秒）- 可配置 */
    public attackInterval: number = 4;

    /** 攻击冷却计时器 */
    private attackCooldown: number = 0;

    /** 每次攻击发射的子弹数量 - 可配置 */
    public bulletCount: number = 20;

    /** 攻击持续时间（秒）- 可配置 */
    public attackDuration: number = 1.6;

    /** 子弹发射回调 */
    private onFireBullets: ((data: AK47BulletData) => void) | null = null;

    /** 当前攻击目标 */
    private currentTargetId: string | null = null;
    private currentTargetPos: Position | null = null;

    /** 回调是否已设置的标志（用于Game类判断） */
    public _bulletCallbackSet: boolean = false;

    /** 本次攻击已发射的子弹数量 */
    private bulletsFired: number = 0;

    /** 子弹连发间隔（秒）- 根据 attackDuration 和 bulletCount 计算 */
    private get bulletFireInterval(): number {
        return this.attackDuration / this.bulletCount;
    }

    /** 子弹发射计时器 */
    private bulletFireTimer: number = 0;

    /** 攻击计时器 */
    private attackTimer: number = 0;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param startPos 起始像素位置
     */
    constructor(id: string, startPos: Position) {
        const stats = { ...AK47_STATS };
        super(id, EnemyType.CAPOO_AK47, startPos, stats);

        // 设置攻击范围：曼哈顿距离 3（菱形）
        this.rangePattern = [
            [0, 0, 0, 1, 0, 0, 0],
            [0, 0, 1, 1, 1, 0, 0],
            [0, 1, 1, 1, 1, 1, 0],
            [1, 1, 1, 1, 1, 1, 1],
            [0, 1, 1, 1, 1, 1, 0],
            [0, 0, 1, 1, 1, 0, 0],
            [0, 0, 0, 1, 0, 0, 0],
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
        const defaultTexture = assetManager.getTexture('capoo_ak47');
        if (defaultTexture) {
            this.sprite = new Sprite(defaultTexture);
            this.sprite.anchor.set(0.5);

            // 保持图片比例，适应格子大小（64x64）
            const maxSize = 60;
            const scale = Math.min(maxSize / defaultTexture.width, maxSize / defaultTexture.height);
            this.sprite.width = defaultTexture.width * scale;
            this.sprite.height = defaultTexture.height * scale;

            // 隐藏默认图形
            this.graphics.visible = false;

            // 精灵图右移 10 像素（修正渲染位置）
            this.sprite.x = 10;

            // 添加精灵图
            this.container.addChild(this.sprite);
        }

        // 获取攻击动画精灵表（3帧水平排列）
        const attackSprite = assetManager.getTexture('capoo_ak47_attack_sprite');
        if (attackSprite) {
            const frameCount = 3;
            const frameWidth = attackSprite.width / frameCount;
            const frameHeight = attackSprite.height;

            for (let i = 0; i < frameCount; i++) {
                const frame = new Texture({
                    source: attackSprite.source,
                    frame: new Rectangle(i * frameWidth, 0, frameWidth, frameHeight),
                });
                this.attackFrameTextures.push(frame);
            }

            console.log(`[AK47 Capoo] 从精灵表加载了 ${this.attackFrameTextures.length} 帧攻击动画`);
        }
    }

    /**
     * 设置子弹发射回调
     */
    public setOnFireBullets(callback: (data: AK47BulletData) => void): void {
        this.onFireBullets = callback;
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
        switch (this.ak47State) {
            case AK47State.MOVING:
                return this.updateMoving(deltaTime);

            case AK47State.ATTACKING:
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
            const defaultTexture = AssetManager.getInstance().getTexture('capoo_ak47');
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
        // 更新攻击计时器
        this.attackTimer += deltaTime;

        // 更新攻击动画帧（循环播放）
        this.frameTimer += deltaTime;
        if (this.frameTimer >= this.frameDuration) {
            this.frameTimer = 0;
            this.currentFrame = (this.currentFrame + 1) % this.attackFrameTextures.length;

            // 更新帧纹理
            if (this.sprite && this.attackFrameTextures[this.currentFrame]) {
                this.sprite.texture = this.attackFrameTextures[this.currentFrame];
            }
        }

        // 机枪式连续发射子弹
        this.bulletFireTimer += deltaTime;
        if (this.bulletFireTimer >= this.bulletFireInterval && this.bulletsFired < this.bulletCount) {
            this.bulletFireTimer = 0;

            // 第一发子弹发射时播放音效
            if (this.bulletsFired === 0) {
                AssetManager.getInstance().playCapooAK47FireSound();
            }

            this.fireSingleBullet();
            this.bulletsFired++;
        }

        // 攻击持续时间结束 AND 子弹发射完毕后切换回移动状态
        const durationDone = this.attackTimer >= this.attackDuration;
        const bulletsDone = this.bulletsFired >= this.bulletCount;

        if (durationDone && bulletsDone) {
            this.currentFrame = 0;
            this.bulletsFired = 0;
            this.bulletFireTimer = 0;
            this.attackTimer = 0;

            // 切换回移动状态
            this.ak47State = AK47State.MOVING;
            this.attackCooldown = this.attackInterval;

            console.log('[AK47 Capoo] 攻击完成，恢复移动');
        }
    }

    /**
     * 发射单发子弹
     */
    private fireSingleBullet(): void {
        if (!this.currentTargetId || !this.currentTargetPos || !this.onFireBullets) {
            return;
        }

        // 从枪口位置发射（向右偏移）
        const startPos = {
            x: this.container.x + 28,
            y: this.container.y + 10,
        };

        // 发射单发子弹
        this.onFireBullets({
            startPos,
            targetPos: this.currentTargetPos,
            targetId: this.currentTargetId,
            damage: this.stats.attack, // 使用基础攻击力
            count: 1, // 每次只发射一发
        });
    }

    /**
     * 检查并尝试攻击范围内的炮台
     * @param towers 炮台信息列表
     * @returns 是否进入攻击状态
     */
    public tryAttack(towers: { id: string; tilePos: Position; pixelPos: Position; isAlive: boolean }[]): boolean {
        // 如果正在攻击或冷却中，不检查
        if (this.ak47State === AK47State.ATTACKING || this.attackCooldown > 0) {
            return false;
        }

        // 查找攻击范围内的炮台
        for (const tower of towers) {
            if (!tower.isAlive) continue;

            // 使用继承的 isInRange 方法检查
            if (this.isInRange(tower.tilePos.x, tower.tilePos.y)) {
                // 进入攻击状态
                this.ak47State = AK47State.ATTACKING;
                this.currentTargetId = tower.id;
                this.currentTargetPos = tower.pixelPos;
                this.currentFrame = 0;
                this.frameTimer = 0;
                this.bulletsFired = 0;
                this.bulletFireTimer = 0;
                this.attackTimer = 0;

                console.log(`[AK47 Capoo] 发现目标 ${tower.id}，进入攻击状态`);
                return true;
            }
        }

        return false;
    }

    /**
     * 是否正在攻击
     */
    public isAttacking(): boolean {
        return this.ak47State === AK47State.ATTACKING;
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
        // 青色椭圆形（代表 Capoo）
        graphics.ellipse(0, 0, 20, 25);
        graphics.fill({ color: 0x00bfff });

        // 棕色 AK47 枪
        graphics.rect(5, -5, 25, 10);
        graphics.fill({ color: 0x8B4513 });
    }
}
