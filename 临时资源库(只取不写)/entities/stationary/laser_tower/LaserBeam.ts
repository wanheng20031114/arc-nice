/**
 * ============================================================
 * 激光射线效果
 * ============================================================
 * 激光塔开火时产生的视觉效果
 * 
 * 特性：
 * - 从炮台位置到目标位置的直线
 * - 短暂持续后消失
 * - 鲜艳的红色激光效果
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../../types';

/**
 * 激光射线类
 */
export class LaserBeam {
    /** 显示容器 */
    private container: Container;

    /** 激光图形 */
    private graphics: Graphics;

    /** 起始位置 */
    private startPos: Position;

    /** 结束位置 */
    private endPos: Position;

    /** 持续时间（秒） */
    private readonly duration: number = 0.3;

    /** 已经过时间（秒） */
    private elapsed: number = 0;

    /** 是否存活 */
    private alive: boolean = true;

    /** 激光宽度 */
    private readonly beamWidth: number = 6;

    /**
     * 构造函数
     * @param startPos 起始位置
     * @param endPos 结束位置
     */
    constructor(startPos: Position, endPos: Position) {
        this.startPos = { ...startPos };
        this.endPos = { ...endPos };

        this.container = new Container();
        this.graphics = new Graphics();
        this.container.addChild(this.graphics);

        // 绘制激光
        this.draw();
    }

    /**
     * 绘制激光
     */
    private draw(): void {
        this.graphics.clear();

        // 计算透明度（随时间衰减）
        const alpha = 1 - (this.elapsed / this.duration);

        // 外层光晕（青蓝色，较粗）
        this.graphics.moveTo(this.startPos.x, this.startPos.y);
        this.graphics.lineTo(this.endPos.x, this.endPos.y);
        this.graphics.stroke({
            color: 0x00aaff,
            width: this.beamWidth * 2,
            alpha: alpha * 0.3
        });

        // 中层光束（亮青色）
        this.graphics.moveTo(this.startPos.x, this.startPos.y);
        this.graphics.lineTo(this.endPos.x, this.endPos.y);
        this.graphics.stroke({
            color: 0x00ffff,
            width: this.beamWidth,
            alpha: alpha * 0.7
        });

        // 核心光束（白色）
        this.graphics.moveTo(this.startPos.x, this.startPos.y);
        this.graphics.lineTo(this.endPos.x, this.endPos.y);
        this.graphics.stroke({
            color: 0xffffff,
            width: this.beamWidth / 2,
            alpha: alpha
        });

        // 起点光晕
        this.graphics.circle(this.startPos.x, this.startPos.y, this.beamWidth * 1.5);
        this.graphics.fill({ color: 0xffffff, alpha: alpha * 0.8 });

        // 终点光晕
        this.graphics.circle(this.endPos.x, this.endPos.y, this.beamWidth * 2);
        this.graphics.fill({ color: 0x00ffff, alpha: alpha * 0.5 });
    }

    /**
     * 更新
     * @param deltaTime 时间增量（秒）
     */
    public update(deltaTime: number): void {
        this.elapsed += deltaTime;

        if (this.elapsed >= this.duration) {
            this.alive = false;
        } else {
            // 重绘以更新透明度
            this.draw();
        }
    }

    /**
     * 是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 获取容器
     */
    public getContainer(): Container {
        return this.container;
    }

    /**
     * 销毁
     */
    public destroy(): void {
        this.container.destroy({ children: true });
    }
}
