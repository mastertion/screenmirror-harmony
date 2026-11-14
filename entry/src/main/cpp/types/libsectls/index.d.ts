/**
 * TLS-PSK 加密传输桥。
 * 密码必须是 Driver Console 显示的十六进制密钥；
 * PSK = hex_decode(密码 + "1A"×16)，identity = Client_identity。
 */
export const tlsConnect: (host: string, port: number, password: string) => Promise<number>;
/**
 * 启动后台读线程，回调语义（与 native 层 TlsEventCallJs 对应）：
 *   - 数据事件：只带第 1 个参数 data（ArrayBuffer），code/message 为 undefined；
 *   - 结束事件（type=1 服务器正常关闭 / type=2 读错误）：data 为 undefined，
 *     code = 1 或 2，message 为说明文字。
 */
export const tlsStartRead: (handle: number,
                            callback: (data: ArrayBuffer, code: number, message: string) => void) => void;
/** 写入数据；失败时 Promise reject（错误描述字符串） */
export const tlsWrite: (handle: number, data: ArrayBuffer) => Promise<void>;
export const tlsClose: (handle: number) => Promise<void>;
export const tlsVersion: () => string;
