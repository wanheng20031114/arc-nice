/**
 * ============================================================
 * 爆炸效果类
 * ============================================================
 * 纯视觉效果，用于显示 AOE 攻击的爆炸动画
 * 
 * 特性：
 * - 橙红色粒子从中心向外扩散
 * - 0.4 秒动画持续时间
 * - 粒子逐渐变小、变淡
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../types';

/**
 * 爆炸粒子数据
 */
interface ExplosionParticle {
    x: number;
    y: number;
    vx: number;
    vy: number;
    size: number;
    alpha: number;
    color: number;
    graphics: Graphics;
}

/**
 * 爆炸效果类
 */
export class ExplosionEffect {
    /** 显示容器 */
    private container: Container;

    /** 粒子列表 */
    private particles: ExplosionParticle[] = [];

    /** 粒子容器 */
    private particleContainer: Container;

    /** 中心闪光 */
    private flash: Graphics;

    /** 动画进度 (0-1) */
    private progress: number = 0;

    /** 动画持续时间（秒） */
    private readonly duration: number = 0.4;

    /** 是否存活 */
    private alive: boolean = true;

    /** 爆炸半径（用于视觉效果） */
    private radius: number;

    /**
     * 构造函数
     * @param position 爆炸中心位置
     * @param radius 爆炸视觉半径（像素）
     */
    constructor(position: Position, radius: number = 64) {
        this.radius = radius;
        this.container = new Container();
        this.container.x = position.x;
        this.container.y = position.y;

        // 创建中心闪光
        this.flash = new Graphics();
        this.container.addChild(this.flash);

        // 创建粒子容器
        this.particleContainer = new Container();
        this.container.addChild(this.particleContainer);

        // 生成粒子
        this.spawnParticles();

        // 绘制初始闪光
        this.drawFlash(1);
    }

    /**
     * 生成爆炸粒子
     */
    private spawnParticles(): void {
        // 更多粒子，更强烈的爆炸感
        const particleCount = 32 + Math.floor(Math.random() * 16);
        const colors = [0xff4500, 0xff6600, 0xffaa00, 0xffcc00, 0xff3300, 0xffff00]; // 更丰富的橙红色渐变

        for (let i = 0; i < particleCount; i++) {
            const angle = Math.random() * Math.PI * 2;
            // 更快的粒子速度，更大范围
            const speed = 150 + Math.random() * 250;
            // 更大的粒子
            const size = 6 + Math.random() * 10;
            const color = colors[Math.floor(Math.random() * colors.length)];

            const graphics = new Graphics();
            graphics.circle(0, 0, size);
            graphics.fill({ color, alpha: 1 });

            this.particleContainer.addChild(graphics);

            this.particles.push({
                x: 0,
                y: 0,
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed,
                size,
                alpha: 1,
                color,
                graphics,
            });
        }

        // 添加少量烟雾粒子（更淡、更小）
        const smokeCount = 4 + Math.floor(Math.random() * 4);
        const smokeColors = [0x444444, 0x555555, 0x666666];
        for (let i = 0; i < smokeCount; i++) {
            const angle = Math.random() * Math.PI * 2;
            const speed = 40 + Math.random() * 60;
            const size = 10 + Math.random() * 12;
            const color = smokeColors[Math.floor(Math.random() * smokeColors.length)];

            const graphics = new Graphics();
            graphics.circle(0, 0, size);
            graphics.fill({ color, alpha: 0.3 });

            this.particleContainer.addChild(graphics);

            this.particles.push({
                x: 0,
                y: 0,
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed - 30, // 烟雾稍微向上飘
                size,
                alpha: 0.3,
                color,
                graphics,
            });
        }
    }

    /**
     * 绘制中心闪光
     * @param intensity 强度 (0-1)
     */
    private drawFlash(intensity: number): void {
        this.flash.clear();

        if (intensity <= 0) return;

        // 更大的外层光晕（橙色）
        this.flash.circle(0, 0, this.radius * 1.2 * intensity);
        this.flash.fill({ color: 0xff6600, alpha: intensity * 0.4 });

        // 中层（黄色）
        this.flash.circle(0, 0, this.radius * 0.7 * intensity);
        this.flash.fill({ color: 0xffaa00, alpha: intensity * 0.6 });

        // 中心亮点（白色）
        this.flash.circle(0, 0, this.radius * 0.3 * intensity);
        this.flash.fill({ color: 0xffffff, alpha: intensity * 0.9 });
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

        // 更新闪光（快速消失）
        const flashIntensity = Math.max(0, 1 - this.progress * 3);
        this.drawFlash(flashIntensity);

        // 更新粒子
        for (const p of this.particles) {
            p.x += p.vx * deltaTime;
            p.y += p.vy * deltaTime;
            p.alpha = 1 - this.progress;

            // 缓慢减速
            p.vx *= 0.98;
            p.vy *= 0.98;

            p.graphics.x = p.x;
            p.graphics.y = p.y;
            p.graphics.alpha = p.alpha;

            // 粒子缩小
            const scale = 1 - this.progress * 0.5;
            p.graphics.scale.set(scale);
        }

        return true;
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
