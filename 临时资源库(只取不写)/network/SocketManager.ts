/**
 * ============================================================
 * Socket.IO 网络管理器
 * ============================================================
 * 管理与服务器的 WebSocket 通信
 */

import { io, Socket } from 'socket.io-client';
import { User, AuthResponse } from '../types';

/**
 * 网络管理器类
 * 单例模式，统一管理网络通信
 */
export class SocketManager {
    /** 单例实例 */
    private static instance: SocketManager;

    /** Socket.IO 客户端实例 */
    private socket: Socket | null = null;

    /** 是否已连接 */
    private connected: boolean = false;

    /** 当前用户信息 */
    private currentUser: User | null = null;

    /** 认证令牌 */
    private authToken: string | null = null;

    /**
     * 私有构造函数（单例模式）
     */
    private constructor() { }

    /**
     * 获取单例实例
     */
    public static getInstance(): SocketManager {
        if (!SocketManager.instance) {
            SocketManager.instance = new SocketManager();
        }
        return SocketManager.instance;
    }

    /**
     * 连接到服务器
     */
    public connect(): Promise<void> {
        return new Promise((resolve, reject) => {
            if (this.connected && this.socket) {
                console.log('[网络] 已连接，跳过重复连接');
                resolve();
                return;
            }

            console.log('[网络] 正在连接服务器...');

            // 创建 Socket.IO 连接
            this.socket = io({
                autoConnect: true,
                reconnection: true,
                reconnectionAttempts: 5,
                reconnectionDelay: 1000,
            });

            // 连接成功
            this.socket.on('connect', () => {
                console.log('[网络] 连接成功，Socket ID:', this.socket?.id);
                this.connected = true;
                resolve();
            });

            // 连接错误
            this.socket.on('connect_error', (error) => {
                console.error('[网络] 连接错误:', error.message);
                reject(error);
            });

            // 断开连接
            this.socket.on('disconnect', (reason) => {
                console.log('[网络] 断开连接，原因:', reason);
                this.connected = false;
            });

            // 重新连接
            this.socket.on('reconnect', (attemptNumber) => {
                console.log('[网络] 重新连接成功，尝试次数:', attemptNumber);
                this.connected = true;
            });
        });
    }

    /**
     * 断开连接
     */
    public disconnect(): void {
        if (this.socket) {
            this.socket.disconnect();
            this.socket = null;
            this.connected = false;
            console.log('[网络] 已断开连接');
        }
    }

    /**
     * 用户登录
     * @param username 用户名
     * @param password 密码
     */
    public async login(username: string, password: string): Promise<AuthResponse> {
        try {
            const response = await fetch('/api/login', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ username, password }),
            });

            const data: AuthResponse = await response.json();

            if (data.success && data.user && data.token) {
                this.currentUser = data.user;
                this.authToken = data.token;
                // 保存到本地存储
                localStorage.setItem('authToken', data.token);
                localStorage.setItem('user', JSON.stringify(data.user));
                console.log('[网络] 登录成功:', data.user.username);
            }

            return data;
        } catch (error) {
            console.error('[网络] 登录请求失败:', error);
            return { success: false, message: '网络请求失败' };
        }
    }

    /**
     * 用户注册
     * @param username 用户名
     * @param password 密码
     */
    public async register(username: string, password: string): Promise<AuthResponse> {
        try {
            const response = await fetch('/api/register', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ username, password }),
            });

            const data: AuthResponse = await response.json();

            if (data.success) {
                console.log('[网络] 注册成功');
            }

            return data;
        } catch (error) {
            console.error('[网络] 注册请求失败:', error);
            return { success: false, message: '网络请求失败' };
        }
    }

    /**
     * 获取当前用户信息
     */
    public async fetchCurrentUser(): Promise<User | null> {
        const token = this.authToken || localStorage.getItem('authToken');

        if (!token) {
            return null;
        }

        try {
            const response = await fetch('/api/user', {
                headers: {
                    'Authorization': `Bearer ${token}`,
                },
            });

            if (!response.ok) {
                throw new Error('获取用户信息失败');
            }

            const data = await response.json();

            if (data.success && data.user) {
                this.currentUser = data.user;
                this.authToken = token;
                return data.user;
            }

            return null;
        } catch (error) {
            console.error('[网络] 获取用户信息失败:', error);
            return null;
        }
    }

    /**
     * 登出
     */
    public logout(): void {
        this.currentUser = null;
        this.authToken = null;
        localStorage.removeItem('authToken');
        localStorage.removeItem('user');
        console.log('[网络] 已登出');
    }

    /**
     * 检查是否已登录
     */
    public isLoggedIn(): boolean {
        return this.currentUser !== null || localStorage.getItem('authToken') !== null;
    }

    /**
     * 获取当前用户
     */
    public getCurrentUser(): User | null {
        if (this.currentUser) {
            return this.currentUser;
        }

        const userStr = localStorage.getItem('user');
        if (userStr) {
            try {
                return JSON.parse(userStr);
            } catch {
                return null;
            }
        }

        return null;
    }

    /**
     * 发送 Socket 事件
     * @param event 事件名
     * @param data 数据
     */
    public emit(event: string, data?: unknown): void {
        if (this.socket && this.connected) {
            this.socket.emit(event, data);
        } else {
            console.warn('[网络] 未连接，无法发送事件:', event);
        }
    }

    /**
     * 监听 Socket 事件
     * @param event 事件名
     * @param callback 回调函数
     */
    public on(event: string, callback: (...args: unknown[]) => void): void {
        if (this.socket) {
            this.socket.on(event, callback);
        }
    }

    /**
     * 移除 Socket 事件监听
     * @param event 事件名
     * @param callback 回调函数
     */
    public off(event: string, callback?: (...args: unknown[]) => void): void {
        if (this.socket) {
            this.socket.off(event, callback);
        }
    }

    /**
     * 检查是否已连接
     */
    public isConnected(): boolean {
        return this.connected;
    }
}
