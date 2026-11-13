/** 主机列表项：把协议层解析结果与 UI 展示状态合并 */
export interface ServerItem {
  name: string;
  ip: string;
  port: number;
  osLabel: string;
  encrypted: boolean;
  passwordRequired: boolean;
  manual: boolean;   // true = 手动添加，false = 局域网发现
  lastSeen: number;  // 时间戳，用于过期清理
}

export function createServerItem(name: string, ip: string, port: number,
                                 osLabel: string, encrypted: boolean,
                                 passwordRequired: boolean, manual: boolean): ServerItem {
  return {
    name: name,
    ip: ip,
    port: port,
    osLabel: osLabel,
    encrypted: encrypted,
    passwordRequired: passwordRequired,
    manual: manual,
    lastSeen: Date.now()
  };
}
