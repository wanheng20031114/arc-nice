/**
 * ============================================================
 * 飘字伤害 UI 组件
 * ============================================================
 * 在敌人头顶显示受到的伤害数值，并具有动画效果
 */

import { Container, Text, TextStyle } from 'pixi.js';
import { Position } from '../types';
import { DamageType } from '../systems/CombatSystem';

/**
 * 飘字伤害类
 */
export class DamagePopup {
    /** 显示容器 */
    private container: Container;

    /** 文本对象 */
    private text: Text;

    /** 存活时间（秒） */
    private lifeTime: number = 0;

    /** 最大存活时间 */
    private readonly maxLifeTime: number = 0.8;

    /** 是否存活 */
    private alive: boolean = true;

    /** 初始位置 */
    private startPos: Position;

    /** 随机偏移方向（X轴） */
    private xRandomOffset: number;

    /**
     * 构造函数
     * @param damage 伤害数值
     * @param type 伤害类型（决定颜色）
     * @param position 弹出位置
     */
    constructor(damage: number, type: DamageType, position: Position) {
        this.container = new Container();
        this.startPos = { ...position };

        // 随机 X 轴微调，防止重叠
        this.xRandomOffset = (Math.random() - 0.5) * 40;
        this.container.x = position.x + this.xRandomOffset;
        this.container.y = position.y - 20; // 初始在头顶一点

        // 决定颜色和样式
        let color = '#ffffff'; // 默认白色
        let fontWeight: 'normal' | 'bold' = 'normal';
        let fontSize = 16;

        switch (type) {
            case DamageType.PHYSICAL:
                color = '#ecf0f1'; // 灰白色
                break;
            case DamageType.MAGICAL:
                color = '#a29bfe'; // 淡紫色/蓝色
                fontWeight = 'bold';
                break;
            case DamageType.TRUE:
                color = '#fab1a0'; // 橙红色
                fontWeight = 'bold';
                fontSize = 20; // 真实伤害更大
                break;
        }

        const style = new TextStyle({
            fontFamily: 'Microsoft YaHei, Arial',
            fontSize: fontSize,
            fill: color,
            fontWeight: fontWeight,
            stroke: { color: '#000000', width: 2 }, // 描边便于阅读
            align: 'center',
        });

        this.text = new Text({
            text: Math.floor(damage).toString(),
            style: style,
        });

        // 锚点设置到中心
        this.text.anchor.set(0.5);
        this.container.addChild(this.text);
    }

    /**
     * 更新动画
     * @param deltaTime 时间增量
     */
    public update(deltaTime: number): boolean {
        this.lifeTime += deltaTime;
        const progress = this.lifeTime / this.maxLifeTime;

        if (progress >= 1) {
            this.alive = false;
            return false;
        }

        // 1. 上升动画：抛物线或线性上升
        this.container.y = this.startPos.y - 20 - (progress * 50);

        // 2. 缩放动画：先变大再变小
        if (progress < 0.2) {
            this.container.scale.set(1 + progress * 2);
        } else {
            this.container.scale.set(1.4 - (progress - 0.2) * 0.5);
        }

        // 3. 透明度动画
        if (progress > 0.5) {
            this.container.alpha = 1 - (progress - 0.5) * 2;
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
