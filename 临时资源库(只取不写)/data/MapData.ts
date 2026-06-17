/**
 * ============================================================
 * 地图数据定义
 * ============================================================
 * 包含关卡的布局、尺寸和自定义配置
 */

import { TileChar, TileType } from '../types';

/**
 * 地图配置接口
 */
export interface MapDataConfig {
    /** 关卡名称 */
    name: string;
    /** 宽度（格子数） */
    width: number;
    /** 高度（格子数） */
    height: number;
    /** 布局数据（二维字符数组） */
    layout: TileChar[][];
    /** 自定义格子图片映射 */
    tileImages?: Partial<Record<TileType, string>>;
}

/**
 * 默认地图数据（28x14）
 * G: 地面, P: 高台, R: 红门, B: 蓝门, O: 障碍物, .: 空白
 */
export const DEFAULT_MAP_DATA: MapDataConfig = {
    name: "默认关卡",
    width: 28,
    height: 14,
    layout: [
        ['O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O'],
        ['O', 'R', 'G', 'G', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'G', 'G', 'G', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'G', 'G', 'G', 'G', 'O'],
        ['O', 'G', 'O', 'O', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'O', 'O', 'O', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'O', 'O', 'O', 'G', 'O'],
        ['O', 'G', 'O', 'P', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'O', 'P', 'O', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'P', 'O', 'G', 'G', 'O'],
        ['O', 'G', 'O', 'P', 'P', 'P', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'P', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'P', 'P', 'P', 'O', 'G', 'O', 'O'],
        ['O', 'R', 'G', 'G', 'G', 'G', 'G', 'P', 'P', 'P', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'P', 'P', 'P', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'O'],
        ['O', 'O', 'O', 'O', 'O', 'O', 'G', 'P', 'P', 'P', 'G', 'O', 'O', 'G', 'O', 'O', 'G', 'P', 'P', 'P', 'G', 'O', 'O', 'O', 'O', 'O', 'G', 'O'],
        ['O', 'O', 'O', 'O', 'O', 'O', 'G', 'P', 'P', 'P', 'G', 'O', 'O', 'G', 'O', 'O', 'G', 'P', 'P', 'P', 'G', 'O', 'B', 'B', 'O', 'O', 'G', 'O'],
        ['O', 'R', 'G', 'G', 'G', 'G', 'G', 'P', 'P', 'P', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'P', 'P', 'P', 'G', 'O', 'G', 'G', 'G', 'G', 'G', 'O'],
        ['O', 'G', 'O', 'P', 'P', 'P', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'P', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'P', 'P', 'P', 'O', 'G', 'O', 'O'],
        ['O', 'G', 'O', 'P', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'O', 'P', 'O', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'G', 'P', 'O', 'G', 'G', 'O'],
        ['O', 'G', 'O', 'O', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'O', 'O', 'O', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'O', 'O', 'O', 'G', 'O'],
        ['O', 'R', 'G', 'G', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'G', 'G', 'G', 'G', 'O', 'P', 'P', 'P', 'P', 'O', 'G', 'G', 'G', 'G', 'G', 'O'],
        ['O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O'],
    ],
    tileImages: {
        [TileType.GROUND]: 'ground',
        [TileType.PLATFORM]: 'platform',
        [TileType.RED_GATE]: 'red_gate',
        [TileType.BLUE_GATE]: 'blue_gate',
        [TileType.OBSTACLE]: 'obstacle',
    }
};
