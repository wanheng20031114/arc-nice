/**
 * ============================================================
 * 光环护盾效果
 * ============================================================
 * 在受近卫塔光环影响的炮塔位置显示淡蓝色方形护盾效果
 * 
 * 特性：
 * - 方形半透明护盾外框
 * - 淡淡闪烁动画
 * - 透明度较高（柔和）
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../types';

/**
 * 光环护盾效果类
 */
export class AuraGlowEffect {
    /** 显示容器 */
    private container: Container;

    /** 护盾图形 */
    private shield: Graphics;

    /** 是否存活 */
    private alive: boolean = true;

    /** 闪烁计时器 */
    private blinkTimer: number = 0;

    /** 闪烁周期（秒） */
    private readonly blinkPeriod: number = 2.0;

    /** 基础透明度（提高到 0.5 以确保更清晰可见） */
    private readonly baseAlpha: number = 0.5;

    /** 闪烁幅度 */
    private readonly blinkAmplitude: number = 0.2;

    /** 格子大小 */
    private readonly tileSize: number = 64;

    /** 护盾颜色（淡蓝色） */
    private readonly shieldColor: number = 0x5dade2;

    /**
     * 构造函数
     * @param position 效果中心像素位置
     */
    constructor(position: Position) {
        this.container = new Container();
        this.container.x = position.x;
        this.container.y = position.y;
        // 禁用交互，让点击穿透到下面的炮塔
        this.container.eventMode = 'none';
        this.container.interactiveChildren = false;

        // 创建护盾图形
        this.shield = this.createShield();
        this.container.addChild(this.shield);
    }

    /**
     * 创建护盾图形
     */
    private createShield(): Graphics {
        const graphics = new Graphics();
        const padding = 2; // 减小内边距
        const size = this.tileSize - padding * 2;
        const cornerRadius = 8;

        // 绘制填充
        graphics.roundRect(-size / 2, -size / 2, size, size, cornerRadius);
        graphics.fill({ color: this.shieldColor, alpha: 0.3 }); // 增加初始透明度

        // 绘制边框
        graphics.roundRect(-size / 2, -size / 2, size, size, cornerRadius);
        graphics.stroke({ color: this.shieldColor, width: 3, alpha: 0.8 }); // 更宽更亮的边框

        return graphics;
    }

    /**
     * 更新效果
     * @param deltaTime 时间增量（秒）
     */
    public update(deltaTime: number): void {
        if (!this.alive) return;

        // 更新闪烁计时器
        this.blinkTimer += deltaTime;
        if (this.blinkTimer > this.blinkPeriod) {
            this.blinkTimer -= this.blinkPeriod;
        }

        // 计算当前透明度（正弦波闪烁）
        const phase = (this.blinkTimer / this.blinkPeriod) * Math.PI * 2;
        const alpha = this.baseAlpha + this.blinkAmplitude * Math.sin(phase);
        this.shield.alpha = alpha;
    }

    /**
     * 检查是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 销毁效果
     */
    public destroy(): void {
        this.alive = false;
        this.shield.destroy();
        this.container.destroy({ children: true });
    }

    /**
     * 获取显示容器
     */
    public getContainer(): Container {
        return this.container;
    }
}
