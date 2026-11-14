import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  SD_DISCOVERY_MAGIC,
  SD_DISCOVERY_PORT,
  SD_DISCOVERY_REPLY_SIZE,
  SdServerOs,
  serverOsName
} from './SdProtocol';

/** 局域网中发现的一台 spacedesk 服务器 */
export class SdServer {
  name: string = '';
  ip: string = '';
  port: number = 0;
  os: number = 0;
  flags: number = 0;
  key: string = '';
  /** 最后一次收到应答的时间戳，用于剔除已下线的服务器 */
  lastSeen: number = 0;

  /** 便于界面展示的名称（"设备名 (Windows 11)"） */
  displayName(): string {
    const osText = serverOsName(this.os);
    if (osText.length > 0 && (this.flags & 3) === 3) {
      return `${this.name} (${osText})`;
    }
    return this.name;
  }
}

/**
 * UDP 发现服务。
 *
 * 协议（逆向自 APK 的 SANetDiscovery / SANetInterface）：
 *   1. 客户端向广播地址 28252 端口发送 UTF-8 字符串
 *      "SPACEDESK-NET-CLIENT\0"（安卓端连发 5 次，间隔很短）
 *   2. 服务器立刻用同一端口回一个 308 字节的应答包：
 *        0..255   服务器名称（UTF-16LE，遇 0x0000 结束）
 *        256..259 服务器 IPv4（A.B.C.D）
 *        260..263 TCP 端口（int32 小端）
 *        264..267 服务器操作系统类型（SdServerOs）
 *        280..283 标志位（低 2 位为 3 表示 spacedesk 品牌服务器）
 */
export class DiscoveryService {
  private udp: socket.UDPSocket | undefined = undefined;
  private timer: number = -1;
  private servers: Map<string, SdServer> = new Map<string, SdServer>();
  private onChanged: (servers: SdServer[]) => void;
  private running: boolean = false;

  constructor(onChanged: (servers: SdServer[]) => void) {
    this.onChanged = onChanged;
  }

  isRunning(): boolean {
    return this.running;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    try {
      const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
      this.udp = udp;
      udp.on('message', (info: socket.SocketMessageInfo) => {
        this.handleReply(info.message, info.remoteInfo);
      });
      const bindAddress: socket.NetAddress = { address: '0.0.0.0', port: 0, family: 1 };
      await udp.bind(bindAddress);
      const options: socket.UDPExtraOptions = { broadcast: true, reuseAddress: true };
      await udp.setExtraOptions(options);
      this.running = true;
      await this.broadcast();
      this.timer = setInterval(() => {
        this.broadcast();
        // 每轮广播后刷新一次列表，让超过 10 秒没应答的服务器从列表中消失
        this.notify();
      }, 1000);
      this.notify();
    } catch (error) {
      const err = error as BusinessError;
      this.running = false;
      throw new Error(`UDP 发现启动失败（${err.code}）：${err.message}`);
    }
  }

  stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    const udp = this.udp;
    this.udp = undefined;
    this.running = false;
    if (udp !== undefined) {
      try {
        udp.off('message');
        udp.close();
      } catch (error) {
        console.info(`udp close error: ${error}`);
      }
    }
  }

  clear(): void {
    this.servers.clear();
    this.notify();
  }

  /** 单次广播；服务器收到后会立即应答 */
  private async broadcast(): Promise<void> {
    const udp = this.udp;
    if (udp === undefined) {
      return;
    }
    const buffer = new ArrayBuffer(SD_DISCOVERY_MAGIC.length);
    const bytes = new Uint8Array(buffer);
    for (let i = 0; i < SD_DISCOVERY_MAGIC.length; i++) {
      bytes[i] = SD_DISCOVERY_MAGIC.charCodeAt(i) & 0xFF;
    }
    const address: socket.NetAddress = { address: '255.255.255.255', port: SD_DISCOVERY_PORT, family: 1 };
    const options: socket.UDPSendOptions = { data: buffer, address: address };
    try {
      await udp.send(options);
    } catch (error) {
      // 部分网络（如仅点对点热点）不允许全局广播，忽略即可，用户仍可手动输入 IP
      const err = error as BusinessError;
      console.info(`spacedesk discovery broadcast failed: ${err.code}`);
    }
  }

  private handleReply(data: ArrayBuffer, remote: socket.SocketRemoteInfo): void {
    if (data.byteLength < SD_DISCOVERY_REPLY_SIZE) {
      return;
    }
    const bytes = new Uint8Array(data);
    const view = new DataView(data);

    let name = '';
    for (let i = 0; i + 1 < 256; i += 2) {
      const code = bytes[i] | (bytes[i + 1] << 8);
      if (code === 0) {
        break;
      }
      name += String.fromCharCode(code);
    }

    let ip = `${bytes[256]}.${bytes[257]}.${bytes[258]}.${bytes[259]}`;
    if (ip === '0.0.0.0' && remote !== undefined) {
      ip = remote.address;
    }
    const port = view.getInt32(260, true);
    const os = view.getInt32(264, true);
    const flags = view.getInt32(280, true);
    if (port <= 0 || port > 65535) {
      return;
    }

    const server = new SdServer();
    server.name = name.trim();
    server.ip = ip;
    server.port = port;
    server.os = os;
    server.flags = flags;
    server.key = `${ip}:${port}`;
    server.lastSeen = Date.now();
    if (server.name.length === 0) {
      server.name = ip;
    }
    if (os === SdServerOs.Unknown && server.name.length === 0) {
      return;
    }

    const existing = this.servers.get(server.key);
    const isNew = existing === undefined;
    this.servers.set(server.key, server);
    if (isNew) {
      this.notify();
    }
  }

  private notify(): void {
    const now = Date.now();
    const list: SdServer[] = [];
    this.servers.forEach((value: SdServer) => {
      // 搜索进行中只展示 10 秒内有应答的活跃服务器
      if (this.running && now - value.lastSeen > 10000) {
        this.servers.delete(value.key);
        return;
      }
      list.push(value);
    });
    this.onChanged(list);
  }
}
