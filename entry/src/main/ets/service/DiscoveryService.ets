/**
 * 局域网主机发现服务
 *
 * 逆向依据（w2.f / i2.* / f.*）：
 *   - 客户端创建临时端口的 DatagramSocket，绑定本机网卡
 *   - 向 255.255.255.255:28252 广播 UTF-8 字符串 "SPACEDESK-NET-CLIENT\0"，连发 5 次
 *   - 同时对已知主机做单播探测
 *   - 服务端回 308 字节 UDP 报文，内含名称/IP/端口/系统类型/标志位
 */
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  NET_PORT, BROADCAST_ADDRESS, DISCOVERY_RETRY,
  buildDiscoveryProbe, parseDiscoveryReply, DiscoveredServer
} from '../common/Protocol';
import { ServerItem, createServerItem } from '../model/ServerInfo';

export type OnServerFound = (server: ServerItem) => void;
export type OnDiscoveryError = (message: string) => void;

export class DiscoveryService {
  private udp: socket.UDPSocket | undefined = undefined;
  private running: boolean = false;
  private timer: number = -1;
  private onFound: OnServerFound | undefined = undefined;
  private onError: OnDiscoveryError | undefined = undefined;
  private knownIps: string[] = [];

  async start(onFound: OnServerFound, onError: OnDiscoveryError, knownIps: string[] = []): Promise<void> {
    this.stop();
    this.onFound = onFound;
    this.onError = onError;
    this.knownIps = knownIps;

    try {
      const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      // broadcast 必须在 bind 之后设置
      await udp.setExtraOptions({
        broadcast: true,
        reuseAddress: true,
        receiveBufferSize: 64 * 1024,
        sendBufferSize: 8 * 1024,
        socketTimeout: 6000
      });
      udp.on('message', (value: socket.SocketMessageInfo): void => {
        this.handleReply(value);
      });
      udp.on('close', (): void => {
        this.running = false;
      });
      this.udp = udp;
      this.running = true;
      await this.probe();
      this.timer = setInterval((): void => {
        this.probe();
      }, 3000);
    } catch (e) {
      const err = e as BusinessError;
      this.report(`发现服务启动失败：${err.code} ${err.message}`);
    }
  }

  /** 广播 + 已知主机单播，各发 DISCOVERY_RETRY 次 */
  private async probe(): Promise<void> {
    if (!this.running || this.udp === undefined) {
      return;
    }
    const data: ArrayBuffer = buildDiscoveryProbe();
    for (let i: number = 0; i < DISCOVERY_RETRY; i++) {
      try {
        await this.udp.send({
          data: data,
          address: { address: BROADCAST_ADDRESS, port: NET_PORT, family: 1 }
        });
      } catch (e) {
        // 部分路由器/网络环境屏蔽受限广播，此时改用子网广播或单播即可，不打断流程
        this.report('广播发送受限，可改用手动添加 IP');
        break;
      }
    }
    for (const ip of this.knownIps) {
      try {
        await this.udp.send({
          data: data,
          address: { address: ip, port: NET_PORT, family: 1 }
        });
      } catch (e) {
        // 单台主机不可达时忽略
      }
    }
  }

  private handleReply(value: socket.SocketMessageInfo): void {
    const raw: ArrayBuffer = value.message;
    const fallbackIp: string = value.remoteInfo ? value.remoteInfo.address : '';
    const parsed: DiscoveredServer | undefined = parseDiscoveryReply(raw, fallbackIp);
    if (parsed === undefined) {
      return;
    }
    if (this.onFound !== undefined) {
      this.onFound(createServerItem(parsed.name, parsed.ip, parsed.port, parsed.osLabel,
        parsed.encrypted, parsed.passwordRequired, false));
    }
  }

  private report(msg: string): void {
    if (this.onError !== undefined) {
      this.onError(msg);
    }
  }

  stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.running = false;
    if (this.udp !== undefined) {
      try {
        this.udp.off('message');
        this.udp.close();
      } catch (e) {
        // 已关闭
      }
      this.udp = undefined;
    }
  }

  isRunning(): boolean {
    return this.running;
  }
}

export const discoveryService: DiscoveryService = new DiscoveryService();
