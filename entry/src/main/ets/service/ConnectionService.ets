/**
 * TCP 会话服务（画面通道 + 音频通道）
 *
 * 逆向依据：
 *   - l2.a(): 连接 host:28252，setTcpNoDelay(true)，trafficClass=224；加密分支为 TLS-PSK
 *   - k2.c(): 连接成功后先发 128B 头 + 334B 身份数据；k2.a() 为音频通道身份包
 *   - e/P2:   每个报文 = [128B 小端包头][payloadLength 字节载荷]
 *   - b$k:    报文类型枚举（本文件覆盖全部 15 种）
 *   - q2/e2/d2: 接收队列、状态机、流控窗口（对应 StreamAssembler + 流控 ACK）
 */
import { socket } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { buffer } from '@kit.ArkTS';
import {
  NET_PORT, HeaderType, Compression, StreamAssembler,
  ParsedPacket, buildDisconnect,
  buildInputEvent, toArrayBuffer, IdentificationOptions
} from '../common/Protocol';
import {
  buildFlowControlAck, buildPasswordAuth, buildAudioIdentification, buildVideoIdentification,
  buildTouchEvent, parseFrameMeta, normalizeRawFrame,
  isH264AnnexB, isJpeg, parseAudioChunk, nowMs,
  MouseAction, TouchAction, KeyAction, KeyModifier,
  PointerSample, PenSample, FrameMeta, AudioChunk
} from '../common/ProtocolEx';
import { audioService } from './AudioService';
import { decodeJpeg, DecodedFrame } from 'libspacedesk.so';

export enum SessionState {
  IDLE = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  DISPLAY_OFF = 3,
  DISCONNECTING = 4,
  DISCONNECTED = 5,
  FAILED = 6,
  RECONNECTING = 7
}

export interface ConnectOptions {
  password: string;
  audioEnabled: boolean;
  autoReconnect: boolean;
  watchdogMs: number;
  pingIntervalMs: number;
  quality: number;
  width: number;
  height: number;
  rotation: number;
}

export interface SessionCallbacks {
  onState: (state: SessionState, detail: string) => void;
  onFrame: (pixelMap: image.PixelMap, frameBytes: number) => void;
  onH264Data: (data: ArrayBuffer) => void;
  onMessage: (text: string) => void;
  onDisconnected: (reason: string) => void;
  onStats: (fps: number, kbps: number, width: number, height: number) => void;
  onRotation: (degrees: number) => void;
  onDisplaySettings: (width: number, height: number) => void;
  onAudio: (chunk: AudioChunk) => void;
}

export class ConnectionService {
  private tcp: socket.TCPSocket | undefined = undefined;
  private audioTcp: socket.TCPSocket | undefined = undefined;
  private assembler: StreamAssembler = new StreamAssembler();
  private audioAssembler: StreamAssembler = new StreamAssembler();
  private callbacks: SessionCallbacks | undefined = undefined;
  private state: SessionState = SessionState.IDLE;
  private renderQueue: Promise<void> = Promise.resolve();

  private host: string = '';
  private port: number = NET_PORT;
  private ident: IdentificationOptions | undefined = undefined;
  private options: ConnectOptions | undefined = undefined;
  private compression: Compression = Compression.MJPEG;

  private watchdogTimer: number = -1;
  private pingTimer: number = -1;
  private statsTimer: number = -1;
  private lastDataAt: number = 0;
  private connectedAt: number = 0;
  private frameCount: number = 0;
  private windowFrames: number = 0;
  private windowBytes: number = 0;
  private totalBytes: number = 0;
  private sequence: number = 0;
  private reconnectCount: number = 0;
  private intentionalClose: boolean = false;
  private remoteWidth: number = 0;
  private remoteHeight: number = 0;
  /** 触摸坐标空间：与身份包声明的设备分辨率一致 */
  private screenW: number = 1320;
  private screenH: number = 2848;
  private lastSendFailAt: number = 0;
  /** 已发送输入事件数（用于 UI 验证触摸通道） */
  inputCount: number = 0;

  async connect(host: string, port: number, opt: IdentificationOptions,
                callbacks: SessionCallbacks, options: ConnectOptions): Promise<void> {
    this.callbacks = callbacks;
    this.host = host;
    this.port = port > 0 ? port : NET_PORT;
    this.ident = opt;
    this.options = options;
    this.compression = opt.compression;
    this.assembler.reset();
    this.audioAssembler.reset();
    this.frameCount = 0;
    this.windowFrames = 0;
    this.windowBytes = 0;
    this.totalBytes = 0;
    this.sequence = 0;
    this.intentionalClose = false;
    this.lastDataAt = Date.now();
    this.setState(SessionState.CONNECTING, host);

    try {
      const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
      tcp.on('message', (value: socket.SocketMessageInfo): void => {
        this.onVideoData(value.message);
      });
      tcp.on('close', (): void => {
        this.onSocketClosed('画面连接已关闭');
      });
      await tcp.connect({
        address: { address: host, port: this.port, family: 1 },
        timeout: 6000
      });
      this.tcp = tcp;
      this.connectedAt = Date.now();

      if (options.password.length > 0) {
        await tcp.send({ data: buildPasswordAuth(options.password) });
      }
      // 2026-11-13 抓包定案：视频通道只发一个身份包，之后【什么都不能再发】。
      // 真机验证：身份包后多发 DISPLAY_SETTINGS/VISIBILITY 服务端会静默断开。
      // 缓冲分辨率通过身份包 [56]/[92] 请求（实测 1920x1080 被服务端接受并按此推流）。
      await tcp.send({ data: buildVideoIdentification(opt.instanceId, opt.deviceName, 0, 0,
        options.width, options.height) });

      this.setState(SessionState.CONNECTED, host);
      this.startTimers();
      if (options.audioEnabled) {
        this.openAudioChannel(host, this.port, opt);
      }
    } catch (e) {
      const err = e as BusinessError;
      this.setState(SessionState.FAILED, `${err.code} ${err.message}`);
      this.notify('连接失败，请检查主机在线、防火墙放行 TCP 28252');
      this.scheduleReconnect();
    }
  }

  /** 音频是独立 TCP 连接，身份包 clientType=AUDIO（对应 k2.a） */
  private async openAudioChannel(host: string, port: number,
                                 opt: IdentificationOptions): Promise<void> {
    try {
      const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
      tcp.on('message', (value: socket.SocketMessageInfo): void => {
        this.onAudioData(value.message);
      });
      await tcp.connect({ address: { address: host, port: port, family: 1 }, timeout: 6000 });
      this.audioTcp = tcp;
      await tcp.send({ data: buildAudioIdentification(opt.instanceId, opt.deviceName) });
    } catch (e) {
      const err = e as BusinessError;
      this.notify(`音频通道未建立：${err.message}`);
    }
  }

  private startTimers(): void {
    this.stopTimers();
    const o: ConnectOptions | undefined = this.options;
    const watchdog: number = o === undefined ? 20000 : o.watchdogMs;

    // 2026-11-13 抓包定案：真 APK 周期发送全零 type=7 ACK（约 190ms 一次），
    // 从不发 type=1 PING。这里以 200ms 全零 ACK 替代原 PING 心跳。
    this.pingTimer = setInterval((): void => {
      if (this.isActive()) {
        this.sendRaw(buildFlowControlAck());
      }
    }, 200);

    this.watchdogTimer = setInterval((): void => {
      if (!this.isActive()) {
        return;
      }
      if (Date.now() - this.lastDataAt > watchdog) {
        this.notify('连接无响应，正在尝试恢复');
        this.scheduleReconnect();
      }
    }, 2000);

    this.statsTimer = setInterval((): void => {
      if (this.callbacks !== undefined) {
        this.callbacks.onStats(this.windowFrames, Math.round(this.windowBytes / 1024),
          this.remoteWidth, this.remoteHeight);
      }
      this.windowFrames = 0;
      this.windowBytes = 0;
    }, 1000);
  }

  private stopTimers(): void {
    if (this.pingTimer >= 0) { clearInterval(this.pingTimer); this.pingTimer = -1; }
    if (this.watchdogTimer >= 0) { clearInterval(this.watchdogTimer); this.watchdogTimer = -1; }
    if (this.statsTimer >= 0) { clearInterval(this.statsTimer); this.statsTimer = -1; }
  }

  private onVideoData(chunk: ArrayBuffer): void {
    this.lastDataAt = Date.now();
    this.windowBytes += chunk.byteLength;
    this.totalBytes += chunk.byteLength;
    const packets: ParsedPacket[] = this.assembler.push(chunk);
    // 串行队列：条带必须按到达顺序合成，禁止并发写整屏缓冲
    for (const pkt of packets) {
      this.renderQueue = this.renderQueue
        .then((): Promise<void> => this.handleVideoPacket(pkt))
        .catch((e: object): void => {
          const err = e as BusinessError;
          this.notify(`帧处理异常：${err.message ?? String(e)}`);
        });
    }
  }

  private onAudioData(chunk: ArrayBuffer): void {
    this.lastDataAt = Date.now();
    const packets: ParsedPacket[] = this.audioAssembler.push(chunk);
    for (const pkt of packets) {
      if (pkt.header.type === HeaderType.AUDIO) {
        const audioChunk: AudioChunk | undefined = parseAudioChunk(pkt.rawHeader, pkt.payload);
        if (audioChunk !== undefined) {
          audioService.push(audioChunk);
          if (this.callbacks !== undefined) {
            this.callbacks.onAudio(audioChunk);
          }
        }
      }
    }
  }

  private async handleVideoPacket(pkt: ParsedPacket): Promise<void> {
    const type: number = pkt.header.type;
    switch (type) {
      case HeaderType.FRAMEBUFFER:
        this.sequence++;
        // 抓包定案：不逐帧回 ACK（全零 ACK 由 200ms 定时器负责），
        // 显示缓冲尺寸从帧头 [8]/[12] 读取。
        await this.renderFrame(parseFrameMeta(pkt.rawHeader), pkt.payload);
        break;
      case HeaderType.PING:
        // 服务端 type=1：回一个全零 ACK 保持活跃
        this.sendRaw(buildFlowControlAck());
        break;
      case HeaderType.DISCONNECT:
        this.notifyDisconnected('主机主动断开连接');
        await this.disconnect();
        break;
      case HeaderType.VISIBILITY:
        // 抓包：服务端开场会推 type=3（[12]=2），语义未定，忽略以免误判息屏
        break;
      case HeaderType.DISPLAY_SETTINGS:
        this.applyDisplaySettings(pkt.payload);
        break;
      case HeaderType.EVT_DISPLAY_SETTINGS:
        this.notify('主机已接受显示设置');
        break;
      case HeaderType.FRAMEBUFFER_FLOW_CONTROL_ACK:
        break;
      case HeaderType.ROTATION:
        if (pkt.payload.length >= 4 && this.callbacks !== undefined) {
          this.callbacks.onRotation(pkt.payload.readInt32LE(0));
        }
        break;
      case HeaderType.AUDIO: {
        const audioChunk: AudioChunk | undefined = parseAudioChunk(pkt.rawHeader, pkt.payload);
        if (audioChunk !== undefined) {
          audioService.push(audioChunk);
        }
        break;
      }
      case HeaderType.IDENTIFICATION:
        this.notify('主机已确认身份');
        break;
      default:
        break;
    }
  }

  private applyDisplaySettings(payload: buffer.Buffer): void {
    if (payload.length < 8) {
      return;
    }
    const w: number = payload.readInt32LE(0);
    const h: number = payload.readInt32LE(4);
    if (w > 0 && h > 0 && w < 65536 && h < 65536) {
      this.remoteWidth = w;
      this.remoteHeight = h;
      if (this.callbacks !== undefined) {
        this.callbacks.onDisplaySettings(w, h);
      }
    }
  }

  /* ------------ 条带合成引擎（2026-11-13 抓包定案） ------------
   * 服务端把 1024x768 显示缓冲拆成横带 JPEG 推送（带宽=[32]，带高=JPEG 高），
   * 每个逻辑更新连发 4 份（内容相同），客户端需：
   *  1. 维护整屏 BGRA 缓冲，按帧头 [24]/[28] 把解码后的带贴回去；
   *  2. 按内容去重，跳过 4 份重复；
   *  3. 限频输出新 PixelMap 供 UI 刷新。
   */
  private fbW: number = 0;
  private fbH: number = 0;
  private fbAb: ArrayBuffer | undefined = undefined;
  private lastBandKey: string = '';
  private lastEmitAt: number = 0;

  private ensureFramebuffer(w: number, h: number): boolean {
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) {
      return false;
    }
    if (this.fbAb !== undefined && this.fbW === w && this.fbH === h) {
      return true;
    }
    this.fbW = w;
    this.fbH = h;
    this.fbAb = new ArrayBuffer(w * h * 4);
    this.lastBandKey = '';
    // 刷成黑色（RGBA: B=0 G=0 R=0 A=255）
    const fill: buffer.Buffer = buffer.from(this.fbAb) as buffer.Buffer;
    for (let i: number = 3; i < fill.length; i += 4) {
      fill.writeUInt8(255, i);
    }
    return true;
  }

  private emitFramebuffer(frameBytes: number): void {
    const now: number = Date.now();
    if (now - this.lastEmitAt < 66) {
      return; // 限频约 15fps
    }
    this.lastEmitAt = now;
    try {
      const opts: image.InitializationOptions = {
        size: { height: this.fbH, width: this.fbW },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.OPAQUE,
        editable: false
      };
      const pixelMap: image.PixelMap = image.createPixelMapSync(this.fbAb as ArrayBuffer, opts);
      this.frameCount++;
      if (this.callbacks !== undefined) {
        this.callbacks.onFrame(pixelMap, frameBytes);
      }
    } catch (e) {
      const err = e as BusinessError;
      this.notify(`整屏合成失败：${err.code}`);
    }
  }

  /** 支持 MJPEG 横带合成 / BGRA 原始帧 / H.264 Annex-B 三条路径 */
  private async renderFrame(meta: FrameMeta, payload: buffer.Buffer): Promise<void> {
    if (payload.length < 4) {
      return;
    }
    this.windowFrames++;

    if (this.compression === Compression.H264 || isH264AnnexB(payload)) {
      if (this.callbacks !== undefined) {
        this.callbacks.onH264Data(toArrayBuffer(payload));
      }
      this.frameCount++;
      return;
    }

    if (!isJpeg(payload)) {
      // 原始帧：按显示缓冲尺寸整帧铺底
      const dw: number = meta.displayWidth > 0 ? meta.displayWidth : this.fbW;
      const dh: number = meta.displayHeight > 0 ? meta.displayHeight : this.fbH;
      if (this.ensureFramebuffer(dw, dh)) {
        const normalized: buffer.Buffer = normalizeRawFrame(payload, meta);
        const pixels: number = this.fbW * this.fbH * 4;
        if (normalized.length >= pixels) {
          // Windows 原始帧是 BGRA，整屏缓冲是 RGBA：交换 R/B 通道
          const raw: buffer.Buffer = buffer.from(normalized.subarray(0, pixels)) as buffer.Buffer;
          for (let i: number = 0; i + 2 < pixels; i += 4) {
            const b: number = raw.readUInt8(i);
            raw.writeUInt8(raw.readUInt8(i + 2), i);
            raw.writeUInt8(b, i + 2);
          }
          const dst: buffer.Buffer = buffer.from(this.fbAb as ArrayBuffer) as buffer.Buffer;
          raw.copy(dst, 0, 0, pixels);
          this.emitFramebuffer(payload.length);
        }
      }
      return;
    }

    // MJPEG 横带
    const dw: number = meta.displayWidth > 0 ? meta.displayWidth : 1024;
    const dh: number = meta.displayHeight > 0 ? meta.displayHeight : 768;
    if (!this.ensureFramebuffer(dw, dh)) {
      return;
    }
    // 内容去重：同一逻辑更新会连发 4 份，仅首份参与合成
    const headLen: number = Math.min(16, payload.length);
    let head: string = '';
    for (let i: number = 0; i < headLen; i += 4) {
      head += payload.readUInt32LE(i).toString(16);
    }
    const key: string = `${meta.x}_${meta.y}_${meta.width}_${meta.height}_${payload.length}_${head}`;
    if (key === this.lastBandKey) {
      return;
    }
    this.lastBandKey = key;

    // 解码：优先原生 stb_image（2026-11-13 真机验证系统 image 框架对该
    // JPEG 解码失败且无错误码，原生解码不依赖系统编解码插件），
    // 失败退系统解码器，并把真实错误信息带给 UI。
    let bw: number = 0;
    let bh: number = 0;
    let bandBuf: buffer.Buffer | undefined = undefined;
    const jpgAb: ArrayBuffer = toArrayBuffer(payload);
    const dec: DecodedFrame = decodeJpeg(jpgAb);
    if (dec.width > 0 && dec.height > 0 &&
        dec.data.byteLength >= dec.width * dec.height * 4) {
      bw = dec.width;
      bh = dec.height;
      bandBuf = buffer.from(dec.data) as buffer.Buffer;
    }
    if (bandBuf === undefined) {
      let band: image.PixelMap | undefined = undefined;
      let lastErrText: string = '';
      try {
        const src: image.ImageSource = image.createImageSource(jpgAb);
        const decodeOpts: image.DecodingOptions = {
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888
        };
        band = await src.createPixelMap(decodeOpts);
      } catch (e) {
        const err = e as Error;
        lastErrText = `RGBA:${err.message}`;
      }
      if (band === undefined) {
        try {
          const src2: image.ImageSource = image.createImageSource(jpgAb);
          band = await src2.createPixelMap();
        } catch (e) {
          const err = e as Error;
          this.notify(`画面带解码失败 ${lastErrText}/默认:${err.message} len=${payload.length}`);
          return;
        }
      }
      const info: image.ImageInfo = await band.getImageInfo();
      bw = info.size.width;
      bh = info.size.height;
      if (bw <= 0 || bh <= 0) {
        return;
      }
      const bandAb: ArrayBuffer = new ArrayBuffer(bw * bh * 4);
      await band.readPixelsToBuffer(bandAb);
      bandBuf = buffer.from(bandAb) as buffer.Buffer;
    }
    // 贴带：逐行拷入整屏缓冲的 [x, y] 处（RGBA 与整屏缓冲一致，整帧自然覆盖全屏）
    const fbBuf: buffer.Buffer = buffer.from(this.fbAb as ArrayBuffer) as buffer.Buffer;
    const bx: number = Math.max(0, Math.min(meta.x, this.fbW - bw));
    const by: number = Math.max(0, Math.min(meta.y, this.fbH - bh));
    const rowBytes: number = Math.min(bw, this.fbW - bx) * 4;
    for (let r: number = 0; r < bh && by + r < this.fbH; r++) {
      const dstOff: number = ((by + r) * this.fbW + bx) * 4;
      const srcOff: number = r * bw * 4;
      bandBuf.copy(fbBuf, dstOff, srcOff, srcOff + rowBytes);
    }
    this.emitFramebuffer(payload.length);
  }

  /* ------------------------- 输入发送 ------------------------- */
  // 2026-11-13 抓包定案：视频通道只接受 type=7 全零 ACK 与 type=12 触摸事件。
  // 鼠标/键盘/设置类报文的准确格式未采集到，发送未定义报文会导致服务端立即断开
  // （真机实测），因此鼠标映射为触摸、键盘/设置暂不上报。

  /** 触摸：归一化坐标按声明的屏尺寸（与身份包一致）换算成设备像素 */
  sendTouch(action: TouchAction, points: PointerSample[]): void {
    for (const p of points) {
      this.sendRaw(buildTouchEvent(action, [p], nowMs(), this.screenW, this.screenH));
      this.inputCount++;
    }
  }

  /** 鼠标模式：映射为触摸事件（服务端自动转换为指针），滚轮/悬停不上报 */
  sendMouse(action: MouseAction, x: number, y: number, buttons: number,
            wheelDelta: number): void {
    if (action === MouseAction.SCROLL || action === MouseAction.HOVER) {
      return;
    }
    const ta: TouchAction = action === MouseAction.DOWN ? TouchAction.DOWN
      : action === MouseAction.UP ? TouchAction.UP : TouchAction.MOVE;
    this.sendRaw(buildTouchEvent(ta,
      [{ id: 0, x: x, y: y, pressure: 1, radius: 0 }], nowMs(), this.screenW, this.screenH));
  }

  /** 键盘：报文格式未定（发送未定义报文会导致服务端断开），暂不上报 */
  sendKeyboard(action: KeyAction, keyCode: number, unicode: number,
               modifiers: number, repeat: number): void {
    this.notify('键盘输入通道尚在调试中，暂未生效');
  }

  /** 手写笔：按触摸处理 */
  sendPen(action: TouchAction, pen: PenSample): void {
    this.sendRaw(buildTouchEvent(action,
      [{ id: 0, x: pen.x, y: pen.y, pressure: 1, radius: 0 }], nowMs(), this.screenW, this.screenH));
  }

  /** 兼容旧调用：单点触摸 */
  sendSimpleTouch(action: number, x: number, y: number): void {
    const a: TouchAction = action === 0 ? TouchAction.DOWN : action === 1 ? TouchAction.UP : TouchAction.MOVE;
    const points: PointerSample[] = [{ id: 0, x: x, y: y, pressure: 1, radius: 0 }];
    this.sendTouch(a, points);
  }

  /** 兼容旧调用：键盘 */
  sendSimpleKeyboard(keyCode: number, action: number): void {
    this.sendKeyboard(action === 1 ? KeyAction.UP : KeyAction.DOWN,
      keyCode, keyCode, KeyModifier.NONE, 0);
  }

  sendLegacyInput(type: HeaderType, x: number, y: number,
                  action: number, extra: number): void {
    this.sendRaw(buildInputEvent(type, x, y, action, extra));
  }

  requestResolution(width: number, height: number, fps: number,
                    rotation: number, quality: number): void {
    // type=6 设置报文发送会导致服务端断开（真机实测），改为提示后走重连生效
    if (this.options !== undefined) {
      this.options.width = width;
      this.options.height = height;
    }
    this.notify('分辨率/帧率将在下次重新连接时生效');
    if (this.ident !== undefined && !this.intentionalClose) {
      this.intentionalClose = true;
      this.reconnectCount = 0;
      this.release();
      this.setState(SessionState.DISCONNECTED, '');
      this.connect(this.host, this.port, this.ident, this.callbacks as SessionCallbacks,
        this.options as ConnectOptions);
    }
  }

  /** 旋转：通过带旋转参数的身份包重连生效（直接发 type=9 会断连） */
  requestRotation(degrees: number): void {
    this.notify('旋转将在下次重新连接时生效');
    if (this.ident !== undefined && !this.intentionalClose) {
      this.intentionalClose = true;
      this.reconnectCount = 0;
      this.release();
      this.setState(SessionState.DISCONNECTED, '');
      this.connect(this.host, this.port, this.ident, this.callbacks as SessionCallbacks,
        this.options as ConnectOptions);
    }
  }

  /** 可见性：type=3 上报会断连，忽略（息屏检测本就不可靠） */
  setVisibility(visible: boolean): void {
  }

  private sendRaw(data: ArrayBuffer): void {
    if (this.tcp === undefined) {
      return;
    }
    this.tcp.send({ data: data }).catch((e: BusinessError): void => {
      const now: number = Date.now();
      if (now - this.lastSendFailAt > 2000) {
        this.lastSendFailAt = now;
        this.notify(`发送失败：${e.message}`);
      }
      // 发送失败说明 socket 已断：立即切状态并触发重连，避免定时器持续报错
      if (!this.intentionalClose &&
          (this.state === SessionState.CONNECTED || this.state === SessionState.DISPLAY_OFF)) {
        this.setState(SessionState.DISCONNECTED, '发送失败');
        this.notifyDisconnected('连接已断开');
        this.scheduleReconnect();
      }
    });
  }

  /* ------------------------- 生命周期 ------------------------- */

  private onSocketClosed(reason: string): void {
    if (this.intentionalClose) {
      return;
    }
    if (this.state === SessionState.CONNECTED || this.state === SessionState.DISPLAY_OFF ||
        this.state === SessionState.CONNECTING) {
      this.setState(SessionState.DISCONNECTED, '');
      this.notifyDisconnected(reason);
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    const o: ConnectOptions | undefined = this.options;
    if (o === undefined || !o.autoReconnect || this.intentionalClose || this.ident === undefined) {
      this.release();
      return;
    }
    if (this.reconnectCount >= 3) {
      this.notify('自动重连已停止，请手动重新连接');
      this.release();
      return;
    }
    this.reconnectCount++;
    this.stopTimers();
    this.releaseSockets();
    this.setState(SessionState.RECONNECTING, `第 ${this.reconnectCount} 次`);
    const opt: IdentificationOptions = this.ident;
    const cb: SessionCallbacks | undefined = this.callbacks;
    const connOpt: ConnectOptions = o;
    const host: string = this.host;
    const port: number = this.port;
    setTimeout((): void => {
      if (cb !== undefined && !this.intentionalClose) {
        this.connect(host, port, opt, cb, connOpt);
      }
    }, 1500 * this.reconnectCount);
  }

  private isActive(): boolean {
    return this.state === SessionState.CONNECTED || this.state === SessionState.DISPLAY_OFF;
  }

  async disconnect(): Promise<void> {
    if (this.state === SessionState.IDLE || this.state === SessionState.DISCONNECTED) {
      return;
    }
    this.intentionalClose = true;
    this.setState(SessionState.DISCONNECTING, '');
    try {
      if (this.tcp !== undefined) {
        await this.tcp.send({ data: buildDisconnect(0) });
      }
    } catch (e) {
      // socket 可能已关闭
    }
    this.release();
    this.setState(SessionState.DISCONNECTED, '');
  }

  private release(): void {
    this.stopTimers();
    this.releaseSockets();
    this.assembler.reset();
    this.audioAssembler.reset();
    this.fbAb = undefined;
    this.fbW = 0;
    this.fbH = 0;
    this.lastBandKey = '';
    audioService.close();
  }

  private releaseSockets(): void {
    if (this.tcp !== undefined) {
      try {
        this.tcp.off('message');
        this.tcp.off('close');
        this.tcp.close();
      } catch (e) {
        // 已关闭
      }
      this.tcp = undefined;
    }
    if (this.audioTcp !== undefined) {
      try {
        this.audioTcp.off('message');
        this.audioTcp.close();
      } catch (e) {
        // 已关闭
      }
      this.audioTcp = undefined;
    }
  }

  private setState(state: SessionState, detail: string): void {
    this.state = state;
    if (this.callbacks !== undefined) {
      this.callbacks.onState(state, detail);
    }
  }

  private notify(text: string): void {
    if (this.callbacks !== undefined) {
      this.callbacks.onMessage(text);
    }
  }

  private notifyDisconnected(reason: string): void {
    if (this.callbacks !== undefined) {
      this.callbacks.onDisconnected(reason);
    }
  }

  getState(): SessionState { return this.state; }
  getFrameCount(): number { return this.frameCount; }
  getTotalBytes(): number { return this.totalBytes; }
  getRemoteWidth(): number { return this.remoteWidth; }
  getRemoteHeight(): number { return this.remoteHeight; }
  getConnectedSeconds(): number {
    return this.connectedAt === 0 ? 0 : Math.floor((Date.now() - this.connectedAt) / 1000);
  }
}

export const connectionService: ConnectionService = new ConnectionService();
