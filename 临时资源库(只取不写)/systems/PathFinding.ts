/**
 * ============================================================
 * A* 寻路系统
 * ============================================================
 * 实现 A* 寻路算法，用于敌人自动寻找从红门到蓝门的最短路径
 * 只允许在地面格子上行走，高台格子不可通行
 */

import { Position, PathNode } from '../types';
import { GameMap } from '../core/GameMap';

/**
 * 寻路系统类
 */
export class PathFinding {
    /** 游戏地图引用 */
    private gameMap: GameMap;

    /**
     * 构造函数
     * @param gameMap 游戏地图实例
     */
    constructor(gameMap: GameMap) {
        this.gameMap = gameMap;
    }

    /**
     * A* 寻路算法
     * 寻找从起点到终点的最短路径
     * 
     * @param start 起点位置（格子坐标）
     * @param end 终点位置（格子坐标）
     * @returns 路径数组（格子坐标），如果无法到达则返回空数组
     */
    public findPath(start: Position, end: Position): Position[] {
        // 开放列表：待探索的节点
        const openList: PathNode[] = [];

        // 关闭列表：已探索的节点
        const closedSet: Set<string> = new Set();

        // 创建起始节点
        const startNode: PathNode = {
            position: start,
            g: 0,
            h: this.heuristic(start, end),
            f: 0,
            parent: null,
        };
        startNode.f = startNode.g + startNode.h;

        openList.push(startNode);

        // A* 主循环
        while (openList.length > 0) {
            // 找到 F 值最小的节点
            let currentIndex = 0;
            for (let i = 1; i < openList.length; i++) {
                if (openList[i].f < openList[currentIndex].f) {
                    currentIndex = i;
                }
            }

            const currentNode = openList[currentIndex];

            // 到达终点，构建路径
            if (currentNode.position.x === end.x && currentNode.position.y === end.y) {
                return this.buildPath(currentNode);
            }

            // 将当前节点从开放列表移到关闭列表
            openList.splice(currentIndex, 1);
            closedSet.add(this.positionToKey(currentNode.position));

            // 获取相邻节点（四方向：上、下、左、右）
            const neighbors = this.getNeighbors(currentNode.position);

            for (const neighborPos of neighbors) {
                const key = this.positionToKey(neighborPos);

                // 跳过已探索的节点
                if (closedSet.has(key)) {
                    continue;
                }

                // 检查是否可通行
                if (!this.gameMap.isWalkable(neighborPos.x, neighborPos.y)) {
                    continue;
                }

                // 计算新的 G 值
                const tentativeG = currentNode.g + 1;

                // 检查是否在开放列表中
                let neighborNode = openList.find(
                    (n) => n.position.x === neighborPos.x && n.position.y === neighborPos.y
                );

                if (!neighborNode) {
                    // 新节点，添加到开放列表
                    neighborNode = {
                        position: neighborPos,
                        g: tentativeG,
                        h: this.heuristic(neighborPos, end),
                        f: 0,
                        parent: currentNode,
                    };
                    neighborNode.f = neighborNode.g + neighborNode.h;
                    openList.push(neighborNode);
                } else if (tentativeG < neighborNode.g) {
                    // 找到更好的路径，更新节点
                    neighborNode.g = tentativeG;
                    neighborNode.f = neighborNode.g + neighborNode.h;
                    neighborNode.parent = currentNode;
                }
            }
        }

        // 无法找到路径
        console.warn('[寻路系统] 无法找到从', start, '到', end, '的路径');
        return [];
    }

    /**
     * 启发式函数：计算曼哈顿距离
     * @param a 位置A
     * @param b 位置B
     */
    private heuristic(a: Position, b: Position): number {
        return Math.abs(a.x - b.x) + Math.abs(a.y - b.y);
    }

    /**
     * 获取相邻的四个方向节点
     * @param pos 当前位置
     */
    private getNeighbors(pos: Position): Position[] {
        return [
            { x: pos.x, y: pos.y - 1 },     // 上
            { x: pos.x, y: pos.y + 1 },     // 下
            { x: pos.x - 1, y: pos.y },     // 左
            { x: pos.x + 1, y: pos.y },     // 右
        ];
    }

    /**
     * 将位置转换为字符串键（用于 Set）
     * @param pos 位置
     */
    private positionToKey(pos: Position): string {
        return `${pos.x},${pos.y}`;
    }

    /**
     * 从终点节点回溯构建完整路径
     * @param endNode 终点节点
     */
    private buildPath(endNode: PathNode): Position[] {
        const path: Position[] = [];
        let currentNode: PathNode | null = endNode;

        while (currentNode !== null) {
            path.unshift(currentNode.position);
            currentNode = currentNode.parent;
        }

        return path;
    }

    /**
     * 寻找到最近蓝门的路径
     * @param start 起点位置（格子坐标）
     * @returns 路径数组，包含目标蓝门位置
     */
    public findPathToNearestBlueGate(start: Position): Position[] {
        const blueGates = this.gameMap.getBlueGates();

        if (blueGates.length === 0) {
            console.warn('[寻路系统] 没有找到蓝门');
            return [];
        }

        // 如果只有一个蓝门，直接寻路
        if (blueGates.length === 1) {
            return this.findPath(start, blueGates[0]);
        }

        // 多个蓝门时，找到最近的一个
        let shortestPath: Position[] = [];
        let shortestLength = Infinity;

        for (const gate of blueGates) {
            const path = this.findPath(start, gate);
            if (path.length > 0 && path.length < shortestLength) {
                shortestPath = path;
                shortestLength = path.length;
            }
        }

        return shortestPath;
    }
}
