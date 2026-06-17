/**
 * ============================================================
 * 游戏内 UI
 * ============================================================
 * 用于在 PixiJS 游戏场景中叠加 HTML UI
 * （本文件预留，当前使用 PixiJS 内置 UI）
 */

/**
 * 游戏UI类
 */
export class GameUI {
    /** 容器元素 */
    private container: HTMLDivElement;

    /** 返回大厅回调 */
    private onBackToLobby: (() => void) | null = null;

    /**
     * 构造函数
     */
    constructor() {
        this.container = this.createContainer();
    }

    /**
     * 创建容器
     */
    private createContainer(): HTMLDivElement {
        const container = document.createElement('div');
        container.id = 'game-ui';
        container.style.cssText = `
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      pointer-events: none;
    `;

        // 顶部返回按钮
        const backBtn = document.createElement('button');
        backBtn.textContent = '← 返回大厅';
        backBtn.className = 'btn btn-secondary';
        backBtn.style.cssText = `
      position: absolute;
      top: 10px;
      right: 20px;
      pointer-events: auto;
      padding: 8px 16px;
      font-size: 12px;
    `;
        backBtn.onclick = () => this.onBackToLobby?.();
        container.appendChild(backBtn);

        return container;
    }

    /**
     * 设置返回大厅回调
     */
    public setOnBackToLobby(callback: () => void): void {
        this.onBackToLobby = callback;
    }

    /**
     * 显示 UI
     */
    public show(parent: HTMLElement): void {
        parent.appendChild(this.container);
    }

    /**
     * 隐藏 UI
     */
    public hide(): void {
        this.container.remove();
    }
}
