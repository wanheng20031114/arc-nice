/**
 * ============================================================
 * 登录页面
 * ============================================================
 * 提供用户登录和注册功能
 */

import { SocketManager } from '../network/SocketManager';
import { AssetManager } from '../core/AssetManager';

/**
 * 登录页面类
 */
export class LoginPage {
    /** 页面容器元素 */
    private container: HTMLDivElement;

    /** 网络管理器 */
    private socketManager: SocketManager;

    /** 登录成功回调 */
    private onLoginSuccess: (() => void) | null = null;

    /**
     * 构造函数
     */
    constructor() {
        this.socketManager = SocketManager.getInstance();
        this.container = this.createContainer();
    }

    /**
     * 创建页面容器
     */
    private createContainer(): HTMLDivElement {
        const container = document.createElement('div');
        container.id = 'login-page';
        container.style.cssText = `
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 20px;
    `;

        // 标题
        const title = document.createElement('h1');
        title.textContent = '星跃塔防';
        title.style.cssText = `
      font-size: 48px;
      color: #e94560;
      margin-bottom: 10px;
      text-shadow: 0 0 20px rgba(233, 69, 96, 0.5);
    `;
        container.appendChild(title);

        // 副标题
        const subtitle = document.createElement('p');
        subtitle.textContent = 'StarJump Tower Defense';
        subtitle.style.cssText = `
      font-size: 18px;
      color: #888;
      margin-bottom: 40px;
    `;
        container.appendChild(subtitle);

        // 表单卡片
        const card = document.createElement('div');
        card.className = 'card';
        card.style.cssText = `
      width: 100%;
      max-width: 400px;
      padding: 32px;
    `;

        // 表单标题
        const formTitle = document.createElement('h2');
        formTitle.textContent = '登录账户';
        formTitle.id = 'form-title';
        formTitle.style.cssText = `
      font-size: 24px;
      margin-bottom: 24px;
      text-align: center;
    `;
        card.appendChild(formTitle);

        // 用户名输入
        const usernameInput = document.createElement('input');
        usernameInput.type = 'text';
        usernameInput.id = 'username';
        usernameInput.placeholder = '用户名';
        usernameInput.className = 'input';
        usernameInput.style.cssText = `
      width: 100%;
      margin-bottom: 16px;
    `;
        card.appendChild(usernameInput);

        // 密码输入
        const passwordInput = document.createElement('input');
        passwordInput.type = 'password';
        passwordInput.id = 'password';
        passwordInput.placeholder = '密码';
        passwordInput.className = 'input';
        passwordInput.style.cssText = `
      width: 100%;
      margin-bottom: 24px;
    `;
        card.appendChild(passwordInput);

        // 错误提示
        const errorMsg = document.createElement('p');
        errorMsg.id = 'error-message';
        errorMsg.style.cssText = `
      color: #e74c3c;
      font-size: 14px;
      margin-bottom: 16px;
      text-align: center;
      display: none;
    `;
        card.appendChild(errorMsg);

        // 登录按钮
        const loginBtn = document.createElement('button');
        loginBtn.textContent = '登录';
        loginBtn.className = 'btn btn-primary';
        loginBtn.style.cssText = `
      width: 100%;
      margin-bottom: 12px;
    `;
        loginBtn.onclick = () => {
            AssetManager.getInstance().playClickSound();
            this.handleLogin();
        };
        card.appendChild(loginBtn);

        // 注册按钮
        const registerBtn = document.createElement('button');
        registerBtn.textContent = '注册新账户';
        registerBtn.className = 'btn btn-secondary';
        registerBtn.style.cssText = `
      width: 100%;
    `;
        registerBtn.onclick = () => {
            AssetManager.getInstance().playClickSound();
            this.handleRegister();
        };
        card.appendChild(registerBtn);

        container.appendChild(card);

        return container;
    }

    /**
     * 处理登录
     */
    private async handleLogin(): Promise<void> {
        const username = (document.getElementById('username') as HTMLInputElement)?.value;
        const password = (document.getElementById('password') as HTMLInputElement)?.value;
        const errorMsg = document.getElementById('error-message');

        if (!username || !password) {
            this.showError('请输入用户名和密码');
            return;
        }

        try {
            const result = await this.socketManager.login(username, password);

            if (result.success) {
                console.log('[登录页] 登录成功');
                this.onLoginSuccess?.();
            } else {
                this.showError(result.message || '登录失败');
            }
        } catch (error) {
            this.showError('网络错误，请重试');
        }
    }

    /**
     * 处理注册
     */
    private async handleRegister(): Promise<void> {
        const username = (document.getElementById('username') as HTMLInputElement)?.value;
        const password = (document.getElementById('password') as HTMLInputElement)?.value;

        if (!username || !password) {
            this.showError('请输入用户名和密码');
            return;
        }

        if (username.length < 3) {
            this.showError('用户名至少3个字符');
            return;
        }

        if (password.length < 6) {
            this.showError('密码至少6个字符');
            return;
        }

        try {
            const result = await this.socketManager.register(username, password);

            if (result.success) {
                this.showError('注册成功，请登录', false);
            } else {
                this.showError(result.message || '注册失败');
            }
        } catch (error) {
            this.showError('网络错误，请重试');
        }
    }

    /**
     * 显示错误/提示信息
     */
    private showError(message: string, isError: boolean = true): void {
        const errorMsg = document.getElementById('error-message');
        if (errorMsg) {
            errorMsg.textContent = message;
            errorMsg.style.display = 'block';
            errorMsg.style.color = isError ? '#e74c3c' : '#27ae60';
        }
    }

    /**
     * 设置登录成功回调
     */
    public setOnLoginSuccess(callback: () => void): void {
        this.onLoginSuccess = callback;
    }

    /**
     * 显示页面
     */
    public show(parent: HTMLElement): void {
        parent.innerHTML = '';
        parent.appendChild(this.container);
    }

    /**
     * 隐藏页面
     */
    public hide(): void {
        this.container.remove();
    }
}
