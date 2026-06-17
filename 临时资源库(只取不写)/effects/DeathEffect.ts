/**
 * ============================================================
 * 死亡特效类
 * ============================================================
 * 通用死亡动画效果，适用于敌人和炮台
 * 效果包括：
 * - 向左旋转 90 度
 * - 红色图层覆盖
 * - 黑色粒子释放
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../types';

/**
 * 黑色粒子数据
 */
interface DeathParticle {
    x: number;
    y: number;
    vx: number;
    vy: number;
    size: number;
    alpha: number;
    graphics: Graphics;
}

/**
 * 死亡特效类
 */
export class DeathEffect {
    /** 显示容器 */
    private container: Container;

    /** 实体快照容器（旋转用） */
    private entitySnapshot: Container;

    /** 红色叠加层 */
    private redOverlay: Graphics;

    /** 粒子列表 */
    private particles: DeathParticle[] = [];

    /** 粒子容器 */
    private particleContainer: Container;

    /** 动画进度 (0-1) */
    private progress: number = 0;

    /** 动画持续时间（秒） */
    private readonly duration: number = 0.5;

    /** 是否存活 */
    private alive: boolean = true;

    /** 初始位置 */
    private position: Position;

    /** 实体尺寸 */
    private entitySize: number;

    /**
     * 构造函数
     * @param position 死亡位置
     * @param entitySize 实体大小（用于创建快照）
     * @param entityColor 实体颜色（用于快照）
     */
    constructor(position: Position, entitySize: number, entityColor: number) {
        this.position = { ...position };
        this.entitySize = entitySize;
        this.container = new Container();
        this.container.x = position.x;
        this.container.y = position.y;

        // 创建实体快照（简化的矩形表示）
        this.entitySnapshot = new Container();
        const entityShape = new Graphics();
        entityShape.rect(-entitySize / 2, -entitySize / 2, entitySize, entitySize);
        entityShape.fill({ color: entityColor });
        this.entitySnapshot.addChild(entityShape);
        this.container.addChild(this.entitySnapshot);

        // 创建红色叠加层
        this.redOverlay = new Graphics();
        this.redOverlay.rect(-entitySize / 2, -entitySize / 2, entitySize, entitySize);
        this.redOverlay.fill({ color: 0xff0000, alpha: 0 });
        this.entitySnapshot.addChild(this.redOverlay);

        // 创建粒子容器
        this.particleContainer = new Container();
        this.container.addChild(this.particleContainer);

        // 生成黑色粒子
        this.spawnParticles();
    }

    /**
     * 生成黑色粒子
     */
    private spawnParticles(): void {
        const particleCount = 8 + Math.floor(Math.random() * 5);
        for (let i = 0; i < particleCount; i++) {
            const size = 3 + Math.random() * 4;
            const angle = Math.random() * Math.PI * 2;
            const speed = 50 + Math.random() * 100;

            const graphics = new Graphics();
            graphics.circle(0, 0, size);
            graphics.fill({ color: 0x1a1a1a });
            graphics.x = 0;
            graphics.y = 0;

            this.particleContainer.addChild(graphics);

            this.particles.push({
                x: 0,
                y: 0,
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed - 50, // 向上偏移
                size,
                alpha: 1,
                graphics,
            });
        }
    }

    /**
     * 更新动画
     * @param deltaTime 时间增量（秒）
     * @returns 是否仍在播放
     */
    public update(deltaTime: number): boolean {
        this.progress += deltaTime / this.duration;

        if (this.progress >= 1) {
            this.alive = false;
            return false;
        }

        // 1. 旋转动画（向左旋转 90 度）
        const targetRotation = -Math.PI / 2; // -90 度
        this.entitySnapshot.rotation = targetRotation * this.easeOutQuad(this.progress);

        // 2. 红色叠加层渐显
        this.redOverlay.clear();
        this.redOverlay.rect(-this.entitySize / 2, -this.entitySize / 2, this.entitySize, this.entitySize);
        this.redOverlay.fill({ color: 0xff0000, alpha: this.progress * 0.6 });

        // 3. 整体透明度渐隐
        this.entitySnapshot.alpha = 1 - this.progress * 0.8;

        // 4. 更新粒子
        for (const p of this.particles) {
            p.x += p.vx * deltaTime;
            p.y += p.vy * deltaTime;
            p.vy += 200 * deltaTime; // 重力
            p.alpha = 1 - this.progress;

            p.graphics.x = p.x;
            p.graphics.y = p.y;
            p.graphics.alpha = p.alpha;
        }

        return true;
    }

    /**
     * 缓动函数（二次方缓出）
     */
    private easeOutQuad(t: number): number {
        return t * (2 - t);
    }

    /**
     * 获取容器
     */
    public getContainer(): Container {
        return this.container;
    }

    /**
     * 是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 销毁
     */
    public destroy(): void {
        this.container.destroy({ children: true });
    }
}
