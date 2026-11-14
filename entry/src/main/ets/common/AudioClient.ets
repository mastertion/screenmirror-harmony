import { socket } from '@kit.NetworkKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  SD_HEADER_SIZE,
  SD_MAX_PAYLOAD,
  SdHeaderType,
  SdPingOption,
  buildAudioIdentification,
  buildPingReply
} from './SdProtocol';

/** 音频通道事件回调 */
export interface AudioClientHandler {
  /** 首个音频包携带的格式参数（声道/采样率/位深） */
  onFormat: (channels: number, sampleRate: number, bitsPerSample: number) => void;
  /** PCM 数据（16-bit LE 交错采样） */
  onPcm: (data: ArrayBuffer) => void;
  onState: (connected: boolean, message: string) => void;
}

/**
 * spacedesk 音频通道客户端（独立 TCP 连接）。
 *
 * 抓包校准（cap2.pcapng 端口 33800，2026-11-13）：
 *  - 连接后发一个 IDENT（clientType=3 音频客户端，OS=3 Android，显示参数全 0，授权=0），
 *    服务器回自己的 IDENT 后即开始推送 Audio(14) 报文，无需其它握手；
 *  - Audio 包头字段：off8 = 声道数(2)、off12 = 采样率(48000)、off16 = 位深(16)、
 *    off20 = 每包字节数(1920 = 2ch × 16bit × 48kHz × 10ms)；
 *  - 负载为原始 PCM（16-bit LE 交错）；
 *  - 服务器会发 Ping(1)，需回 EchoReply；无音频流控（不需要 ACK）。
 */
export class AudioClient {
  private tcp: socket.TCPSocket | undefined = undefined;
  private handler: AudioClientHandler;
  private buffer: Uint8Array = new Uint8Array(256 * 1024);
  private length: number = 0;
  private closing: boolean = false;
  private connected: boolean = false;

  // ---- 播放器 ----
  private renderer: audio.AudioRenderer | undefined = undefined;
  private writeQueue: ArrayBuffer[] = [];
  private writing: boolean = false;
  private formatSeen: boolean = false;
  /** 播放缓冲上限（包数，每包 10ms），超过丢最旧防止延迟累积 */
  private maxQueue: number = 40;

  constructor(handler: AudioClientHandler) {
    this.handler = handler;
  }

  isConnected(): boolean {
    return this.connected;
  }

  async connect(ip: string, port: number, clientId: string, deviceName: string): Promise<boolean> {
    this.closing = false;
    this.length = 0;
    this.formatSeen = false;
    this.handler.onState(false, '音频通道连接中');

    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(info.message);
    });
    tcp.on('close', () => {
      if (!this.closing) {
        this.connected = false;
        this.handler.onState(false, '音频通道已关闭');
      }
    });
    tcp.on('error', (error: BusinessError) => {
      if (!this.closing) {
        this.connected = false;
        this.handler.onState(false, `音频通道错误 ${error.code}`);
      }
    });

    try {
      const address: socket.NetAddress = { address: ip, port: port, family: 1 };
      const options: socket.TCPConnectOptions = { address: address, timeout: 5000 };
      await tcp.connect(options);
    } catch (error) {
      const err = error as BusinessError;
      this.connected = false;
      this.handler.onState(false, `音频连接失败（${err.code}）`);
      this.closeSocket();
      return false;
    }

    this.connected = true;
    const ok = await this.send(buildAudioIdentification(clientId, deviceName));
    if (!ok) {
      this.handler.onState(false, '音频 IDENT 发送失败');
      this.closeSocket();
      return false;
    }
    this.handler.onState(true, '音频通道已建立');
    return true;
  }

  /** 释放连接与播放器 */
  async disconnect(): Promise<void> {
    this.closeSocket();
    const renderer = this.renderer;
    this.renderer = undefined;
    this.writeQueue = [];
    if (renderer !== undefined) {
      try {
        await renderer.stop();
        await renderer.release();
      } catch (error) {
        console.info(`audio renderer release: ${error}`);
      }
    }
  }

  private closeSocket(): void {
    this.closing = true;
    this.connected = false;
    const tcp = this.tcp;
    this.tcp = undefined;
    if (tcp !== undefined) {
      try {
        tcp.off('message');
        tcp.off('close');
        tcp.off('error');
        tcp.close();
      } catch (error) {
        console.info(`audio socket close: ${error}`);
      }
    }
  }

  private async send(data: ArrayBuffer): Promise<boolean> {
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
      console.warn(`audio send failed: ${err.code}`);
      return false;
    }
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
        console.error(`audio invalid payload length ${payloadLength}`);
        this.length = 0;
        return;
      }
      const total = SD_HEADER_SIZE + payloadLength;
      if (this.length < total) {
        return;
      }
      this.dispatch(this.buffer.subarray(0, total));
      this.buffer.copyWithin(0, total, this.length);
      this.length -= total;
      if (this.closing) {
        return;
      }
    }
  }

  private dispatch(raw: Uint8Array): void {
    const headerView = new DataView(raw.buffer, raw.byteOffset, SD_HEADER_SIZE);
    const type = headerView.getInt32(0, true);
    switch (type) {
      case SdHeaderType.Audio: {
        const payload = raw.slice(SD_HEADER_SIZE);
        if (payload.length === 0) {
          return;
        }
        if (!this.formatSeen) {
          this.formatSeen = true;
          const channels = headerView.getInt32(8, true);
          const sampleRate = headerView.getInt32(12, true);
          const bits = headerView.getInt32(16, true);
          this.handler.onFormat(channels, sampleRate, bits);
          this.ensureRenderer(channels, sampleRate, bits);
        }
        this.enqueuePcm(payload.buffer as ArrayBuffer);
        break;
      }
      case SdHeaderType.Ping: {
        const option = headerView.getInt32(12, true);
        if (option === SdPingOption.EchoRequest) {
          this.send(buildPingReply());
        }
        break;
      }
      case SdHeaderType.Disconnect: {
        this.handler.onState(false, '服务器断开音频通道');
        this.closeSocket();
        break;
      }
      default:
        break;
    }
  }

  // ---------------- PCM 播放 ----------------

  private enqueuePcm(data: ArrayBuffer): void {
    if (this.writeQueue.length >= this.maxQueue) {
      // 播放跟不上：丢最旧的缓冲，音频宁可丢不能积压
      this.writeQueue.shift();
    }
    this.writeQueue.push(data);
    if (!this.writing) {
      this.pump();
    }
  }

  private ensureRenderer(channels: number, sampleRate: number, bits: number): boolean {
    if (this.renderer !== undefined) {
      return true;
    }
    try {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: sampleRate,
        channels: channels,
        sampleFormat: bits === 24 ? audio.AudioSampleFormat.SAMPLE_FORMAT_S24LE
          : bits === 32 ? audio.AudioSampleFormat.SAMPLE_FORMAT_S32LE
            : audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };
      const rendererInfo: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
      const options: audio.AudioRendererOptions = {
        streamInfo: streamInfo,
        rendererInfo: rendererInfo
      };
      audio.createAudioRenderer(options).then((renderer: audio.AudioRenderer) => {
        if (this.closing) {
          // 通道已断开才收到创建结果：立即释放，避免泄漏一个在播的渲染器
          renderer.release().catch(() => {
          });
          return;
        }
        this.renderer = renderer;
        renderer.start().catch((error: BusinessError) => {
          console.warn(`audio renderer start failed: ${error.code}`);
        });
      }).catch((error: BusinessError) => {
        console.warn(`audio create renderer failed: ${error.code}`);
        this.handler.onState(false, '音频播放器创建失败');
      });
      return true;
    } catch (error) {
      console.warn(`audio renderer init error: ${error}`);
      return false;
    }
  }

  private async pump(): Promise<void> {
    this.writing = true;
    try {
      while (this.writeQueue.length > 0) {
        const renderer = this.renderer;
        if (renderer === undefined) {
          return;
        }
        const chunk = this.writeQueue.shift();
        if (chunk === undefined || chunk.byteLength === 0) {
          continue;
        }
        let offset = 0;
        const bytes = new Uint8Array(chunk);
        while (offset < bytes.length) {
          if (this.renderer === undefined || this.closing) {
            return;
          }
          const view = bytes.buffer.slice(offset);
          try {
            const written = await this.renderer.write(view);
            if (written <= 0) {
              // 缓冲满：稍等再写同一块
              await new Promise<void>((resolve) => setTimeout(resolve, 5));
              continue;
            }
            offset += written;
          } catch (error) {
            const err = error as BusinessError;
            console.warn(`audio write failed: ${err.code}`);
            return;
          }
        }
      }
    } finally {
      this.writing = false;
      // pump 期间又有新包入队：再拉一轮
      if (this.writeQueue.length > 0 && this.renderer !== undefined && !this.closing) {
        this.pump();
      }
    }
  }
}
