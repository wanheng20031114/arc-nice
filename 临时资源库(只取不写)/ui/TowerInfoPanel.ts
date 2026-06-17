/**
 * ============================================================
 * 炮台信息面板
 * ============================================================
 * 显示选中炮台的名称、属性和状态
 * 现在支持：
 * - 显示在炮台右侧
 * - 底部的撤销部署按钮
 */

import { Container, Graphics, Text, TextStyle } from 'pixi.js';
import { Tower } from '../entities/stationary/Tower';
import { Position } from '../types';
import { AssetManager } from '../core/AssetManager';

/**
 * 炮台信息面板类
 */
export class TowerInfoPanel {
    /** PixiJS 容器 */
    private container: Container;

    /** 背景图形 */
    private background: Graphics;

    /** 标题文本 */
    private titleText: Text;

    /** 撤销按钮 */
    private removeButton: Container;

    /** 属性文本列表 */
    private statsTexts: Record<string, Text> = {};

    /** 面板宽度 */
    private readonly width: number = 160;

    /** 面板高度 */
    private readonly height: number = 180;

    /** 当前选中的炮台 */
    private currentTower: Tower | null = null;

    /** 撤销部署回调 */
    private onRemoveTower: ((tower: Tower) => void) | null = null;

    /**
     * 构造函数
     */
    constructor() {
        this.container = new Container();
        this.background = new Graphics();
        this.container.addChild(this.background);

        // 创建标题
        const titleStyle = new TextStyle({
            fontFamily: 'Microsoft YaHei, Arial',
            fontSize: 14,
            fill: '#ffffff',
            fontWeight: 'bold',
        });
        this.titleText = new Text({ text: '单位信息', style: titleStyle });
        this.titleText.x = 10;
        this.titleText.y = 8;
        this.container.addChild(this.titleText);

        // 初始化属性文本
        this.createStatsTexts();

        // 创建撤销按钮（底部）
        this.removeButton = this.createRemoveButton();
        this.container.addChild(this.removeButton);

        // 默认隐藏
        this.container.visible = false;
    }

    /**
     * 创建撤销部署按钮（底部居中）
     */
    private createRemoveButton(): Container {
        const btn = new Container();
        const btnWidth = this.width - 20;
        const btnHeight = 28;
        btn.x = 10;
        btn.y = this.height - btnHeight - 10;

        // 按钮背景
        const bg = new Graphics();
        bg.roundRect(0, 0, btnWidth, btnHeight, 6);
        bg.fill({ color: 0xe74c3c, alpha: 0.9 });
        btn.addChild(bg);

        // 按钮文字
        const textStyle = new TextStyle({
            fontFamily: 'Microsoft YaHei, Arial',
            fontSize: 12,
            fill: '#ffffff',
            fontWeight: 'bold',
        });
        const btnText = new Text({ text: '✕ 撤销部署', style: textStyle });
        btnText.x = (btnWidth - btnText.width) / 2;
        btnText.y = (btnHeight - btnText.height) / 2;
        btn.addChild(btnText);

        // 交互设置
        btn.eventMode = 'static';
        btn.cursor = 'pointer';
        btn.on('pointertap', (event) => {
            event.stopPropagation();
            AssetManager.getInstance().playClickSound();
            this.handleRemove();
        });

        // 悬停效果
        btn.on('pointerover', () => {
            bg.clear();
            bg.roundRect(0, 0, btnWidth, btnHeight, 6);
            bg.fill({ color: 0xc0392b, alpha: 1 });
        });
        btn.on('pointerout', () => {
            bg.clear();
            bg.roundRect(0, 0, btnWidth, btnHeight, 6);
            bg.fill({ color: 0xe74c3c, alpha: 0.9 });
        });

        return btn;
    }

    /**
     * 处理撤销部署
     */
    private handleRemove(): void {
        if (this.currentTower && this.onRemoveTower) {
            this.onRemoveTower(this.currentTower);
            this.hide();
        }
    }

    /**
     * 设置撤销部署回调
     */
    public setOnRemoveTower(callback: (tower: Tower) => void): void {
        this.onRemoveTower = callback;
    }

    /**
     * 创建属性文本项
     */
    private createStatsTexts(): void {
        const statsKeys = [
            { key: 'health', label: '❤ 生命' },
            { key: 'attack', label: '⚔ 攻击' },
            { key: 'defense', label: '🛡 防御' },
            { key: 'magicResist', label: '✨ 法抗' },
            { key: 'attackSpeed', label: '⚡ 攻速' },
        ];

        const textStyle = new TextStyle({
            fontFamily: 'Microsoft YaHei, Arial',
            fontSize: 11,
            fill: '#cccccc',
        });

        let yOffset = 32;
        for (const item of statsKeys) {
            const labelText = new Text({ text: `${item.label}:`, style: textStyle });
            labelText.x = 10;
            labelText.y = yOffset;
            this.container.addChild(labelText);

            const valueText = new Text({ text: '0', style: textStyle });
            valueText.x = 80;
            valueText.y = yOffset;
            this.container.addChild(valueText);

            this.statsTexts[item.key] = valueText;
            yOffset += 20;
        }
    }

    /**
     * 显示炮台信息
     * @param tower 选中的炮台
     * @param towerPixelPos 炮台的像素位置（用于计算面板位置）
     * @param defenseBonus 额外防御加成（如近卫塔光环）
     */
    public show(tower: Tower, towerPixelPos?: Position, defenseBonus: number = 0): void {
        this.currentTower = tower;
        const stats = tower.getStats();
        this.titleText.text = tower.getName();

        // 更新文本内容
        this.statsTexts['health'].text = `${Math.ceil(stats.health)}/${stats.maxHealth}`;
        this.statsTexts['attack'].text = stats.attack.toString();
        // 显示实际防御力（包含光环加成）
        const actualDefense = stats.defense + defenseBonus;
        if (defenseBonus > 0) {
            // 有加成时显示为 "总数(+加成)" 格式
            this.statsTexts['defense'].text = `${actualDefense}(+${defenseBonus})`;
        } else {
            this.statsTexts['defense'].text = actualDefense.toString();
        }
        this.statsTexts['magicResist'].text = stats.magicResist.toString();
        // 攻速格式化：如果是小数则保留最多3位，整数则直接显示
        const speedValue = Number.isInteger(stats.attackSpeed)
            ? stats.attackSpeed.toString()
            : parseFloat(stats.attackSpeed.toFixed(3)).toString();
        this.statsTexts['attackSpeed'].text = `${speedValue}/秒`;

        // 绘制背景
        this.drawBackground();

        // 如果提供了炮台位置，则将面板放在炮台右侧
        if (towerPixelPos) {
            this.container.x = towerPixelPos.x + 40;  // 炮台右侧偏移
            this.container.y = towerPixelPos.y - this.height / 2;  // 垂直居中
        }

        this.container.visible = true;
    }

    /**
     * 绘制面板背景
     */
    private drawBackground(): void {
        this.background.clear();

        // 半透明深色框
        this.background.roundRect(0, 0, this.width, this.height, 8);
        this.background.fill({ color: 0x1a1a2e, alpha: 0.85 });
        this.background.stroke({ color: 0x4a4a6a, width: 1 });

        // 标题分割线
        this.background.moveTo(8, 28);
        this.background.lineTo(this.width - 8, 28);
        this.background.stroke({ color: 0x4a4a6a, width: 1 });
    }

    /**
     * 隐藏面板
     */
    public hide(): void {
        this.container.visible = false;
        this.currentTower = null;
    }

    /**
     * 获取显示容器
     */
    public getContainer(): Container {
        return this.container;
    }

    /**
     * 设置位置
     */
    public setPosition(x: number, y: number): void {
        this.container.x = x;
        this.container.y = y;
    }
}
