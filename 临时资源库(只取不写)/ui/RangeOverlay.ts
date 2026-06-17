/**
 * ============================================================
 * 攻击范围覆盖层
 * ============================================================
 * 在地图上渲染炮台的攻击范围高亮
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../types';

/**
 * 攻击范围覆盖层类
 */
export class RangeOverlay {
    /** PixiJS 容器 */
    private container: Container;

    /** 高亮图形 */
    private graphics: Graphics;

    /** 格子大小 */
    private readonly tileSize: number = 64;

    /**
     * 构造函数
     */
    constructor() {
        this.container = new Container();
        this.graphics = new Graphics();
        this.container.addChild(this.graphics);

        // 设置容器在底层但层级高于地图
        this.container.eventMode = 'none';
        this.container.alpha = 0.4;
    }

    /**
     * 显示指定炮台的攻击范围
     * @param tiles 范围内的格子列表
     * @param mapX 地图容器的 X 偏移（用于对齐）
     * @param mapY 地图容器的 Y 偏移
     */
    public show(tiles: Position[]): void {
        this.graphics.clear();

        // 绘制半透明蓝色方块
        for (const tile of tiles) {
            this.graphics.rect(
                tile.x * this.tileSize,
                tile.y * this.tileSize,
                this.tileSize,
                this.tileSize
            );
            this.graphics.fill({ color: 0x3498db });

            // 绘制细边框
            this.graphics.rect(
                tile.x * this.tileSize,
                tile.y * this.tileSize,
                this.tileSize,
                this.tileSize
            );
            this.graphics.stroke({ color: 0xffffff, width: 1 });
        }

        this.container.visible = true;
    }

    /**
     * 隐藏范围显示
     */
    public hide(): void {
        this.container.visible = false;
        this.graphics.clear();
    }

    /**
     * 获取容器
     */
    public getContainer(): Container {
        return this.container;
    }
}
