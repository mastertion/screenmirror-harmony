import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { tlsConnect, tlsStartRead, tlsWrite, tlsClose } from 'libsectls.so';
import {
  SD_HEADER_SIZE,
  SD_MAX_PAYLOAD,
  SdHeaderType,
  SdIdentConfig,
  SdKeyAction,
  SdPacket,
  SdPingOption,
  SdTouchAction,
  SdTouchPoint,
  buildDisconnect,
  buildEventDisplaySettings,
  buildFramebufferAck,
  buildIdentification,
  buildKeyboard,
  buildMouse,
  buildPingReply,
  buildPingRequest,
  buildRotation,  buildTouch,
  parsePacket,
  SdStreamState,
  SdDisconnectReason
} from './SdProtocol';

/** 连接状态 */
export enum SdConnState {
  Idle = 0,
  Connecting = 1,
  Connected = 2,
  Closed = 3,
  Failed = 4
}

/** 会话事件回调 */
export interface SdClientHandler {
  onState: (state: SdConnState, message: string) => void;
  onFrame: (packet: SdPacket) => void;
  onVisibility: (visible: number) => void;
  onServerDisconnect: (reason: number) => void;
  onDisplaySettings: (state: number) => void;
  /** 对本客户端 Ping 请求的往返延迟（毫秒），用于连接质量显示 */
  onPingRtt?: (rttMs: number) => void;
}

/**
 * spacedesk TCP 会话客户端。
 *
 * 一条网络连接内的收包格式：
 *   [128 字节包头][payloadLength 字节负载] 反复出现，需要自己做粘包/拆包。
 *
 * 帧缓冲流控：每处理完一帧（或每 4 个分片）回一个 FramebufferAck(7)，
 * 服务器收到 ACK 才会继续推送下一帧。
 */
export class SdClient {
  private tcp: socket.TCPSocket | undefined = undefined;
  /** TLS-PSK 连接句柄（>= 0 表示加密模式） */
  private tlsHandle: number = -1;
  private handler: SdClientHandler;
  private buffer: Uint8Array = new Uint8Array(256 * 1024);
  private length: number = 0;
  private closing: boolean = false;
  private pingTimer: number = -1;
  private pingSentAt: number = 0;
  private connected: boolean = false;
  private frames: number = 0;

  constructor(handler: SdClientHandler) {
    this.handler = handler;
  }

  isConnected(): boolean {
    return this.connected;
  }

  /** 已收到的帧数，便于调试 */
  frameCount(): number {
    return this.frames;
  }

  /** 渲染层画完一帧后调用，告诉服务器可以继续推下一帧 */
  async sendFramebufferAck(): Promise<void> {
    await this.send(buildFramebufferAck());
  }

  /**
   * 连接服务器。
   * password 为 Driver Console 显示的十六进制密钥：非空时走 TLS-PSK 加密通道，
   * 否则走明文连接（电脑端需关闭 Password Protection and Encryption）。
   */
  async connect(ip: string, port: number, config: SdIdentConfig, password?: string): Promise<boolean> {
    if (password !== undefined && password.length > 0) {
      return await this.connectTls(ip, port, config, password);
    }
    return await this.connectPlain(ip, port, config);
  }

  /** TLS-PSK 加密连接：native 层握手成功后注册读回调，后续收发都经 libsectls */
  private async connectTls(ip: string, port: number, config: SdIdentConfig, password: string): Promise<boolean> {
    this.closing = false;
    this.length = 0;
    this.frames = 0;
    this.tlsHandle = -1;
    this.handler.onState(SdConnState.Connecting, `正在连接 ${ip}:${port}（加密）`);

    let handle = -1;
    try {
      handle = await tlsConnect(ip, port, password);
    } catch (error) {
      const message = (error instanceof Error) ? error.message : `${error}`;
      this.connected = false;
      this.handler.onState(SdConnState.Failed, `加密连接失败：${message}`);
      return false;
    }
    if (handle < 0) {
      this.connected = false;
      this.handler.onState(SdConnState.Failed, '加密连接失败');
      return false;
    }
    this.tlsHandle = handle;

    tlsStartRead(handle, (data: ArrayBuffer, code: number, message: string) => {
      if (code > 0) {
        // code=1 服务器正常关闭，code=2 读错误
        if (!this.closing) {
          this.connected = false;
          const text = (message !== undefined && message.length > 0) ? message : '服务器已关闭连接';
          this.handler.onState(code === 1 ? SdConnState.Closed : SdConnState.Failed, text);
        }
        return;
      }
      this.onData(data);
    });

    this.connected = true;
    const identification = buildIdentification(config);
    const ok = await this.send(identification);
    if (!ok) {
      this.handler.onState(SdConnState.Failed, '发送识别包失败');
      this.close();
      return false;
    }
    this.handler.onState(SdConnState.Connected, '已连接（加密），等待画面');
    this.startPing();
    return true;
  }

  private async connectPlain(ip: string, port: number, config: SdIdentConfig): Promise<boolean> {
    this.closing = false;
    this.length = 0;
    this.frames = 0;
    this.handler.onState(SdConnState.Connecting, `正在连接 ${ip}:${port}`);

    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(info.message);
    });
    tcp.on('close', () => {
      if (!this.closing) {
        this.connected = false;
        this.handler.onState(SdConnState.Closed, '服务器已关闭连接');
      }
    });
    tcp.on('error', (error: BusinessError) => {
      if (!this.closing) {
        this.connected = false;
        this.handler.onState(SdConnState.Failed, `网络错误 ${error.code}`);
      }
    });

    try {
      const address: socket.NetAddress = { address: ip, port: port, family: 1 };
      const options: socket.TCPConnectOptions = { address: address, timeout: 5000 };
      await tcp.connect(options);
    } catch (error) {
      const err = error as BusinessError;
      this.connected = false;
      this.handler.onState(SdConnState.Failed, `连接失败（${err.code}）：${err.message}`);
      this.close();
      return false;
    }

    this.connected = true;
    const identification = buildIdentification(config);
    const ok = await this.send(identification);
    if (!ok) {
      this.handler.onState(SdConnState.Failed, '发送识别包失败');
      this.close();
      return false;
    }
    this.handler.onState(SdConnState.Connected, '已连接，等待画面');
    this.startPing();
    return true;
  }

  close(): void {
    this.closing = true;
    this.connected = false;
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
    const handle = this.tlsHandle;
    if (handle >= 0) {
      this.tlsHandle = -1;
      tlsClose(handle).catch((error: BusinessError) => {
        console.info(`tls close error: ${error}`);
      });
      this.handler.onState(SdConnState.Closed, '已断开');
      return;
    }
    const tcp = this.tcp;
    this.tcp = undefined;
    if (tcp !== undefined) {
      try {
        tcp.off('message');
        tcp.off('close');
        tcp.off('error');
        tcp.close();
      } catch (error) {
        console.info(`socket close error: ${error}`);
      }
    }
    this.handler.onState(SdConnState.Closed, '已断开');
  }

  /** 正常断开：先按协议通知服务器 */
  async disconnect(): Promise<void> {
    if (this.connected) {
      await this.send(buildDisconnect(SdDisconnectReason.GracefulRegular));
    }
    this.close();
  }

  async send(data: ArrayBuffer): Promise<boolean> {
    const handle = this.tlsHandle;
    if (handle >= 0) {
      try {
        await tlsWrite(handle, data);
        return true;
      } catch (error) {
        const message = (error instanceof Error) ? error.message : `${error}`;
        console.warn(`tls send failed: ${message}`);
        return false;
      }
    }
    const tcp = this.tcp;
    if (tcp === undefined) {
      return false;
    }
    const options: socket.TCPSendOptions = { data: data };
    try {
      await tcp.send(options);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`tcp send failed: ${err.code}`);
      return false;
    }
  }

  // ---------------- 输入事件 ----------------

  async sendTouch(x: number, y: number, displayWidth: number, displayHeight: number,
                  action: SdTouchAction, points: SdTouchPoint[]): Promise<void> {
    const packet = buildTouch(x, y, displayWidth, displayHeight, action, 0, points, Date.now());
    await this.send(packet);
  }

  async sendKey(keyCode: number, action: SdKeyAction): Promise<void> {
    await this.send(buildKeyboard(keyCode, action, 0));
  }

  /** 以 Unicode 字符方式输入一个字符（中文/符号也能输入） */
  async sendChar(codePoint: number): Promise<void> {
    await this.send(buildKeyboard(0, SdKeyAction.Text, codePoint));
  }

  async sendMouse(x: number, y: number, flags: number, wheel: number): Promise<void> {
    await this.send(buildMouse(x, y, flags, wheel));
  }

  async sendRotation(rotation: number): Promise<void> {
    await this.send(buildRotation(rotation));
  }

  async setStreamState(state: SdStreamState): Promise<void> {
    await this.send(buildEventDisplaySettings(state));
  }

  // ---------------- 收包 ----------------

  private onData(data: ArrayBuffer): void {
    const source = new Uint8Array(data);
    if (this.length + source.length > this.buffer.length) {
      let capacity = this.buffer.length;
      const needed = this.length + source.length;
      while (capacity < needed) {
        capacity = capacity * 2;
      }
      const bigger = new Uint8Array(capacity);
      bigger.set(this.buffer.subarray(0, this.length));
      this.buffer = bigger;
    }
    this.buffer.set(source, this.length);
    this.length += source.length;
    this.drain();
  }

  private drain(): void {
    while (this.length >= SD_HEADER_SIZE) {
      const view = new DataView(this.buffer.buffer, 0, SD_HEADER_SIZE);
      const payloadLength = view.getInt32(4, true);
      if (payloadLength < 0 || payloadLength > SD_MAX_PAYLOAD) {
        console.error(`invalid payload length ${payloadLength}, drop connection`);
        this.length = 0;
        this.handler.onState(SdConnState.Failed, '收到非法报文长度');
        this.close();
        return;
      }
      const total = SD_HEADER_SIZE + payloadLength;
      if (this.length < total) {
        return;
      }
      const packet = parsePacket(this.buffer.subarray(0, total));
      this.buffer.copyWithin(0, total, this.length);
      this.length -= total;
      this.dispatch(packet);
      if (this.closing) {
        return;
      }
    }
  }

  private dispatch(packet: SdPacket): void {
    switch (packet.headerType) {
      case SdHeaderType.Framebuffer: {
        this.frames++;
        // 流控交给渲染层：只有在画面真正画完之后才回 ACK，
        // 否则服务器会按网络速度灌帧，解码永远追不上（表现为持续丢帧）。
        this.handler.onFrame(packet);
        break;
      }
      case SdHeaderType.Ping: {
        if (packet.pingOption === SdPingOption.EchoRequest) {
          this.send(buildPingReply());
        } else if (packet.pingOption === SdPingOption.EchoReply
          && this.pingSentAt > 0 && this.handler.onPingRtt !== undefined) {
          // 服务器对我们 Ping 请求的应答：算往返延迟
          this.handler.onPingRtt(Date.now() - this.pingSentAt);
        }
        break;
      }
      case SdHeaderType.Visibility: {
        this.handler.onVisibility(packet.visibility);
        break;
      }
      case SdHeaderType.Disconnect: {
        this.handler.onServerDisconnect(packet.disconnectReason);
        this.close();
        break;
      }
      case SdHeaderType.DisplaySettings: {
        this.handler.onDisplaySettings(packet.streamState);
        break;
      }
      default:
        break;
    }
  }

  /** 每 5 秒发一次 Ping 请求，避免空闲断开 */
  private startPing(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
    }
    this.pingTimer = setInterval(() => {
      if (this.connected) {
        this.pingSentAt = Date.now();
        this.send(buildPingRequest());
      }
    }, 5000);
  }
}
