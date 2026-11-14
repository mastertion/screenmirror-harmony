import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { router, promptAction, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';
import { SdClient, SdClientHandler, SdConnState } from '../common/SdClient';
import { AudioClient } from '../common/AudioClient';
import { H264Decoder } from '../common/H264Decoder';
import {
  loadSettings, saveSettings, sanitizeAscii, SdSettings, toIdentConfig,
  getIpPassword, setIpPassword, clearIpPassword
} from '../common/SdSettings';
import { toServerKeyCode } from '../common/KeyMapping';
import {
  SdMouseButton,
  SdCompression,
  SdKeyAction,
  SdPacket,
  SdStreamState,
  SdTouchAction,
  SdTouchPoint
} from '../common/SdProtocol';

interface DrawSize {
  w: number;
  h: number;
}

class DisplayParams {
  ip: string = '';
  port: number = 0;
  name: string = '';
  width: number = 1280;
  height: number = 720;
  fps: number = 30;
}

@Entry
@Component
struct Display {
  @State statusText: string = '正在连接…';
  @State connected: boolean = false;
  @State showOverlay: boolean = true;
  @State statsText: string = '';
  @State diagText: string = '';
  @State pingMs: number = -1;
  @State paused: boolean = false;
  @State audioText: string = '';
  @State showKeyBar: boolean = false;
  @State lockCtrl: boolean = false;
  @State lockAlt: boolean = false;
  @State lockShift: boolean = false;
  @State lockMeta: boolean = false;
  // 连接时按 IP 询问密码：无记录/上次失败都会弹；仅收到首帧（密码正确）才按 IP 落盘
  @State pwdDialogVisible: boolean = false;
  @State pwdInput: string = '';
  @State pwdHint: string = '';
  @State pwdIpLabel: string = '';
  /** 本次连接尝试所用的密码（含用户刚输入尚未验证的），供成功后绑定 IP 保存 */
  private sessionPassword: string = '';
  /** 本页是否已发起过至少一次连接（区分「用户主动连接」与「自动重连」） */
  private sessionStarted: boolean = false;
  /** 弹窗等待用户输密码时挂起自动重连，避免两套流程互打架 */
  private awaitingPassword: boolean = false;
  /** 关闭旧连接期间屏蔽其回调，避免旧 client 的 Closed 被误判成新连接失败 */
  private suppressStaleState: boolean = false;
  /** 用户明确选过「明文连接」却仍连不上（服务器多半开了密码保护），失败时应重新询问 */
  private triedExplicitPlain: boolean = false;
  /** 本次会话是否曾收到过首帧（用于区分「密码错误」与「连上后掉线」） */
  private passwordVerified: boolean = false;
  /** 「已连接但零帧」看门狗触发次数，避免把会话占用误判成密码错误 */
  private noFrameWatchdogCount: number = 0;

  private renderSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderSettings);
  private client: SdClient | undefined = undefined;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private appSettings: SdSettings = new SdSettings();
  private params: DisplayParams = new DisplayParams();

  private canvasReady: boolean = false;
  private vpWidth: number = 0;
  private vpHeight: number = 0;
  private frameWidth: number = 1280;
  private frameHeight: number = 720;

  private decodeQueue: SdPacket[] = [];
  private activeDecodes: number = 0;
  // 并发解码（对齐安卓 APK 的 4 路 round-robin 解码线程）：每个 strip 解出来后直接按 rect
  // 画到主画布；各 strip 只落自己的位置，顺序无关。明文高码率下并发能压住解码延迟。
  private maxConcurrentDecodes: number = 4;
  private drawnFrames: number = 0;
  private statWindowStart: number = 0;
  private droppedFrames: number = 0;
  private stripsReceived: number = 0;
  private decodeErrors: number = 0;
  private lastCompression: number = -1;
  private lastRectText: string = '-';
  private firstFrameTimer: number = -1;
  private gotFirstFrame: boolean = false;
  /** 首帧真正绘制成功后才收起遮罩，避免“连上但解码失败”时只剩黑屏 */
  private firstFrameDrawn: boolean = false;
  private h264: H264Decoder | undefined = undefined;
  private h264Failed: boolean = false;
  private autoReconnectTimer: number = -1;
  private autoReconnectAttempts: number = 0;
  private userClosing: boolean = false;
  private audioClient: AudioClient | undefined = undefined;
  // 鼠标模式：拖拽状态
  private dragging: boolean = false;
  private lastMouseMoveAt: number = 0;
  // 鼠标模式：双指点按 = 右键
  private twoFingerDownAt: number = 0;
  private twoFingerMoved: boolean = false;
  // 旋转联动：上次发给服务器的方向（true=横屏）
  private sentLandscape: boolean = false;
  private sentRotationOnce: boolean = false;
  private requestedPlay: boolean = false;
  // 整帧（屏幕）尺寸：取自帧缓冲包头 offset 8/12（width/height），每包都带、恒定=整屏分辨率
  // （如 1920x1080）。与安卓一致——绝不用 strip 的 rect 边界去"收敛"，rect 只是该条带在整帧
  // 内的位置，用它推算整帧会把 1554 误当整宽，导致画面整体缩放错位→黑屏。
  private fullFrameW: number = 0;
  private fullFrameH: number = 0;
  // 诊断用：最近一帧的包尺寸与分片标记
  private lastPktW: number = 0;
  private lastPktH: number = 0;
  private lastFrag: number = 0;
  // 鼠标模式（触控板）手势状态
  private tapDownAt: number = 0;
  private tapDownVpX: number = 0;
  private tapDownVpY: number = 0;
  private tapMoved: boolean = false;
  private wheelTracking: boolean = false;
  private wheelLastY: number = 0;
  private wheelAccum: number = 0;

  aboutToAppear(): void {
    this.startSession();
  }

  aboutToDisappear(): void {
    this.userClosing = true;
    this.cancelAutoReconnect();
    this.clearFirstFrameTimer();
    this.restoreWindowSettings();
    this.stopAudio();
    if (this.h264 !== undefined) {
      this.h264.release();
      this.h264 = undefined;
    }
    const client = this.client;
    if (client !== undefined) {
      client.disconnect();
    }
  }

  /** 按设置建立音频通道（独立 TCP 连接，clientType=音频） */
  private startAudio(): void {
    const audioClient = new AudioClient({
      onFormat: (channels: number, sampleRate: number, bitsPerSample: number) => {
        console.info(`audio format: ${channels}ch ${sampleRate}Hz ${bitsPerSample}bit`);
      },
      onPcm: (data: ArrayBuffer) => {
        // PCM 由 AudioClient 内部排队播放
      },
      onState: (connected: boolean, message: string) => {
        this.audioText = connected ? '' : message;
        if (connected) {
          console.info(`audio: ${message}`);
        }
      }
    });
    this.audioClient = audioClient;
    audioClient.connect(this.params.ip, this.params.port,
      this.appSettings.clientId, sanitizeAscii(this.appSettings.deviceName))
      .then((ok: boolean) => {
        if (!ok) {
          this.stopAudio();
        }
      });
  }

  private stopAudio(): void {
    const audioClient = this.audioClient;
    this.audioClient = undefined;
    if (audioClient !== undefined) {
      audioClient.disconnect().catch((error: BusinessError) => {
        console.warn(`audio disconnect failed: ${error}`);
      });
    }
  }

  /**
   * 显示页窗口环境：
   * - 按设置锁定屏幕方向（1=横屏 2=竖屏 0=跟随系统自动旋转）
   * - 副屏使用期间保持屏幕常亮
   */
  private applyWindowSettings(): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      const orientation = this.appSettings.orientation;
      let pref = window.Orientation.AUTO_ROTATION_RESTRICTED;
      if (orientation === 1) {
        pref = window.Orientation.LANDSCAPE;
      } else if (orientation === 2) {
        pref = window.Orientation.PORTRAIT;
      }
      win.setPreferredOrientation(pref).catch((error: BusinessError) => {
        console.warn(`set orientation failed: ${error.code}`);
      });
      win.setWindowKeepScreenOn(true).catch((error: BusinessError) => {
        console.warn(`set keep screen on failed: ${error.code}`);
      });
    }).catch((error: BusinessError) => {
      console.warn(`get last window failed: ${error.code}`);
    });
  }

  /** 离开显示页：恢复跟随系统方向、取消常亮 */
  private restoreWindowSettings(): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      win.setPreferredOrientation(window.Orientation.UNSPECIFIED)
        .catch((error: BusinessError) => {
          console.warn(`restore orientation failed: ${error.code}`);
        });
      win.setWindowKeepScreenOn(false).catch((error: BusinessError) => {
        console.warn(`restore keep screen on failed: ${error.code}`);
      });
    }).catch((error: BusinessError) => {
      console.warn(`get last window failed: ${error.code}`);
    });
  }

  private clearFirstFrameTimer(): void {
    if (this.firstFrameTimer >= 0) {
      clearTimeout(this.firstFrameTimer);
      this.firstFrameTimer = -1;
    }
  }

  private cancelAutoReconnect(): void {
    if (this.autoReconnectTimer >= 0) {
      clearTimeout(this.autoReconnectTimer);
      this.autoReconnectTimer = -1;
    }
  }

  /**
   * 异常断线/连上无画面时按 2s → 5s → 10s 退避自动重连，最多 3 次。
   * 服务器同时只保留一个显示会话，重连前会先发 Disconnect 释放名额。
   */
  private scheduleAutoReconnect(message: string): void {
    if (this.userClosing || this.awaitingPassword || this.autoReconnectTimer >= 0) {
      return;
    }
    // 设置里关闭了自动重连：只提示
    if (!this.appSettings.autoReconnect) {
      this.statusText = `${message}；自动重连已关闭`;
      this.showOverlay = true;
      return;
    }
    if (this.autoReconnectAttempts >= 3) {
      this.statusText = `${message}；自动重连已停止，请点“重连”`;
      this.showOverlay = true;
      return;
    }
    const delays: number[] = [2000, 5000, 10000];
    const index = Math.min(this.autoReconnectAttempts, delays.length - 1);
    const delay = delays[index];
    this.autoReconnectAttempts++;
    this.showOverlay = true;
    this.statusText = `${message}；${delay / 1000} 秒后自动重连（第 ${this.autoReconnectAttempts} 次）`;
    this.autoReconnectTimer = setTimeout(() => {
      this.autoReconnectTimer = -1;
      this.runAutoReconnect();
    }, delay);
  }

  private async runAutoReconnect(): Promise<void> {
    if (this.userClosing) {
      return;
    }
    const old = this.client;
    if (old !== undefined) {
      await old.disconnect();
      this.client = undefined;
    }
    this.statusText = '正在自动重连…';
    await this.startSession();
  }

  private buildHandler(): SdClientHandler {
    return {
      onState: (state: SdConnState, message: string) => {
        if (this.suppressStaleState) {
          return;
        }
        this.statusText = message;
        this.connected = state === SdConnState.Connected;
        if (state === SdConnState.Connected) {
          this.startFirstFrameWatchdog();
          // 连接建立后立即同步当前窗口方向给服务器
          if (this.vpWidth > 0 && this.vpHeight > 0) {
            this.sendRotationIfNeeded(this.vpWidth >= this.vpHeight);
          }
        } else if (state === SdConnState.Failed || state === SdConnState.Closed) {
          this.clearFirstFrameTimer();
          this.showOverlay = true;
          if (this.awaitingPassword || this.userClosing) {
            return;
          }
          // TLS-PSK 握手失败 = 密码错误/服务端改了密码；即使之前连成功过也要重新询问。
          const authFailure = message.indexOf('加密连接失败') >= 0
            || message.indexOf('handshake') >= 0
            || message.indexOf('tls') >= 0
            || message.indexOf('TLS') >= 0;
          if (authFailure || !this.passwordVerified) {
            // 首帧之前就失败：密码错误、服务端改了密码、或服务端开了密码保护而客户端走了明文
            // —— 都按「密码需要重新输入」处理，不进入固定次数自动重连。
            this.onConnectFailedBeforeFrame(message, authFailure);
            return;
          }
          this.scheduleAutoReconnect(message);
        }
      },
      onFrame: (packet: SdPacket) => {
        this.stripsReceived++;
        this.lastCompression = packet.compression;
        this.lastRectText = `${packet.rectLeft},${packet.rectTop}-${packet.rectRight},${packet.rectBottom}`;
        this.lastPktW = packet.width;
        this.lastPktH = packet.height;
        this.lastFrag = packet.fragment;
        // 整帧（屏幕）尺寸直接取自帧缓冲包头的 width/height（offset 8/12），与安卓一致：
        // 每包都携带、且恒等于整屏分辨率（如 1920x1080）。strip 的 rect 只是该条带在整帧
        // 内的位置，绝不能用来推算整帧尺寸（否则把 1554 误当整宽，整体缩放错位→黑屏）。
        const fw = packet.width;
        const fh = packet.height;
        if (fw > 0 && fh > 0) {
          this.frameWidth = fw;
          this.frameHeight = fh;
          this.fullFrameW = fw;
          this.fullFrameH = fh;
        }
        if (!this.gotFirstFrame) {
          this.gotFirstFrame = true;
          this.onFirstFrameSuccess();
          this.clearFirstFrameTimer();
          this.cancelAutoReconnect();
          this.autoReconnectAttempts = 0;
          // 先不要收起遮罩：解码真正成功后再收起，避免“连上但解码失败”只剩黑屏。
          // 这里记下首帧信息，便于排查“黑屏”问题。
          const cname = packet.compression === SdCompression.Mjpeg ? 'MJPEG'
            : packet.compression === SdCompression.H264 ? 'H264' : `${packet.compression}`;
          this.diagText = `首帧已到达: 压缩=${cname} 分辨率=${packet.width}×${packet.height}`;
          this.statusText = '已收到首帧，正在解码…';
        }
        if (this.decodeQueue.length >= this.maxConcurrentDecodes * 3) {
          // 解码明显跟不上：丢最旧的待解码片，优先保证画面最新
          this.decodeQueue.shift();
          this.droppedFrames++;
        }
        this.decodeQueue.push(packet);
        this.pumpDecodes();
        this.updateStats();
      },
      onVisibility: (visible: number) => {
        console.info(`server visibility => ${visible}`);
        // 服务端推流默认处于“未播放”状态（display settings=0），只推光标/预览小图，
        // 必须在收到可见性=1 后主动发 Play 才会开始推送全屏帧；否则服务端超时断开 → 黑屏。
        // iOS 官方 viewer 会发这条命令，原生客户端也必发。
        if (visible === 1 && !this.requestedPlay) {
          this.requestedPlay = true;
          this.client?.setStreamState(SdStreamState.Play).catch((error: BusinessError) => {
            console.warn(`send play failed: ${error.code}`);
          });
        }
      },
      onServerDisconnect: (reason: number) => {
        this.statusText = `服务器断开连接（原因 ${reason}）`;
        this.showOverlay = true;
      },
      onDisplaySettings: (state: number) => {
        console.info(`server display settings => ${state}`);
      },
      onPingRtt: (rttMs: number) => {
        this.pingMs = rttMs;
        this.updateStats();
      }
    };
  }

  /**
   * 连上后 8 秒仍没有任何帧时给出可操作提示：
   * 实测 spacedesk 服务端同时只保留一个显示会话，旧会话未正常断开时会“连上但零帧”。
   */
  private startFirstFrameWatchdog(): void {
    this.clearFirstFrameTimer();
    this.gotFirstFrame = false;
    this.firstFrameTimer = setTimeout(() => {
      this.firstFrameTimer = -1;
      if (this.gotFirstFrame || this.userClosing || this.awaitingPassword) {
        return;
      }
      this.noFrameWatchdogCount++;
      // 连上了却始终没有画面：先按原逻辑回退 H.264 / 自动重连一次，
      // 连续多轮仍零帧且密码从未验证成功，才按「密码错误」重新询问，
      // 避免把服务端会话占用误判成密码问题。
      if (!this.passwordVerified && this.noFrameWatchdogCount >= 2) {
        this.onConnectFailedBeforeFrame('已连接但未收到画面', false);
        return;
      }
      // H.264 模式 8 秒仍无首帧：自动回退 MJPEG 并重连（V1 看门狗行为）
      if (this.appSettings.encoding === SdCompression.H264) {
        this.appSettings.encoding = SdCompression.Mjpeg;
        saveSettings(this.context, this.appSettings).catch((error: BusinessError) => {
          console.warn(`save fallback encoding failed: ${error.code}`);
        });
        promptAction.showToast({ message: 'H.264 无视频输出，已自动回退 MJPEG' });
      }
      // 先断开（释放服务器上可能残留的唯一显示会话），再自动重连
      this.scheduleAutoReconnect('已连接但收不到画面（服务器可能仍占着上一次的会话）');
    }, 8000);
  }

  private async startSession(): Promise<void> {
    this.cancelAutoReconnect();
    const raw = router.getParams() as DisplayParams;
    if (raw !== undefined && raw.ip !== undefined && raw.ip.length > 0) {
      this.params = raw;
    } else if (this.params.ip.length === 0) {
      this.statusText = '缺少连接参数';
      return;
    }
    this.userClosing = false;
    this.requestedPlay = false;
    this.fullFrameW = 0;
    this.fullFrameH = 0;

    this.frameWidth = this.params.width;
    this.frameHeight = this.params.height;

    try {
      this.appSettings = await loadSettings(this.context);
    } catch (error) {
      console.error(`load settings failed: ${error}`);
    }
    this.applyWindowSettings();
    this.sentRotationOnce = false;

    // 密码按 IP 绑定：只有首次进入本页（用户主动点「连接」）才去查/问密码；
    // 自动重连、手动重连一律复用本次会话已确定的密码，避免反复弹窗。
    if (!this.sessionStarted) {
      const saved = getIpPassword(this.appSettings.passwordBook, this.params.ip);
      if (saved === undefined) {
        this.openPasswordDialog('');
        return;
      }
      // 之前该 IP 是明文连接成功：若现在连不上，多半是服务端开启了密码保护
      this.triedExplicitPlain = saved.length === 0;
      await this.connectWithPassword(saved);
      return;
    }
    await this.connectWithPassword(this.sessionPassword);
  }

  /** 用给定密码真正发起连接（密码可为空 = 明文连接） */
  private async connectWithPassword(password: string): Promise<void> {
    this.sessionStarted = true;
    this.sessionPassword = password;
    this.awaitingPassword = false;
    this.pwdDialogVisible = false;
    this.showOverlay = true;
    this.statusText = password.length > 0 ? '正在建立加密连接…' : '正在连接…';

    // 重连前先释放旧连接，避免服务器上残留唯一显示会话
    const oldClient = this.client;
    if (oldClient !== undefined) {
      this.suppressStaleState = true;
      oldClient.close();
      this.suppressStaleState = false;
    }
    const config = toIdentConfig(this.appSettings, this.params.width, this.params.height, this.params.fps);
    const client = new SdClient(this.buildHandler());
    this.client = client;
    this.statWindowStart = Date.now();
    this.gotFirstFrame = false;
    this.firstFrameDrawn = false;
    this.stripsReceived = 0;
    this.decodeErrors = 0;
    this.drawnFrames = 0;
    this.droppedFrames = 0;
    this.decodeQueue = [];
    this.activeDecodes = 0;
    const ok = await client.connect(this.params.ip, this.params.port, config, password);
    if (!ok) {
      // 失败回调可能已经弹出密码框，别把遮罩重新盖回去
      if (!this.awaitingPassword) {
        this.showOverlay = true;
      }
      return;
    }
    // 视频接通后再开音频通道（服务器同时只保留一个音频会话）；
    // 加密模式下服务器不受理音频连接（TLS+音频通道会被忽略），自动跳过
    this.paused = false;
    if (this.appSettings.audioEnabled && password.length === 0
      && this.audioClient === undefined) {
      this.startAudio();
    }
  }

  /** 连接时弹出密码输入框；hint 非空表示上次连接失败，需要重新输入 */
  private openPasswordDialog(hint: string): void {
    this.cancelAutoReconnect();
    this.clearFirstFrameTimer();
    this.awaitingPassword = true;
    this.pwdIpLabel = this.params.ip;
    // 失败重输时预填上一次输入，用户只需改正错误字符；首次则为空
    this.pwdInput = this.sessionPassword;
    this.pwdHint = hint;
    this.pwdDialogVisible = true;
    this.showOverlay = false;
    this.statusText = hint.length > 0 ? hint : '请输入连接密码';
  }

  /** 首帧到达 = 密码与压缩模式都被服务端接受，此时才把密码绑定到该 IP 落盘 */
  private onFirstFrameSuccess(): void {
    this.passwordVerified = true;
    this.noFrameWatchdogCount = 0;
    const book = setIpPassword(this.appSettings.passwordBook, this.params.ip, this.sessionPassword);
    if (book !== this.appSettings.passwordBook) {
      this.appSettings.passwordBook = book;
      saveSettings(this.context, this.appSettings).catch((error: BusinessError) => {
        console.warn(`save ip password failed: ${error.code}`);
      });
    }
  }

  /** 首帧之前就失败：密码错误 / 服务端改了密码 / 明文撞上加密服务端 —— 重新询问，不走自动重连 */
  private onConnectFailedBeforeFrame(message: string, invalidateSaved: boolean): void {
    this.cancelAutoReconnect();
    this.clearFirstFrameTimer();
    // 先置位，避免下面 close() 触发的 onState(Closed) 递归进来
    this.awaitingPassword = true;
    const client = this.client;
    this.client = undefined;
    if (client !== undefined) {
      client.close();
    }
    this.stopAudio();
    // 握手类失败说明该 IP 存的密码已失效：清掉记录，下次连接直接重新询问。
    // 「已连接但无画面」可能是服务端会话占用，保留记录、只重新询问。
    if (invalidateSaved) {
      const book = clearIpPassword(this.appSettings.passwordBook, this.params.ip);
      if (book !== this.appSettings.passwordBook) {
        this.appSettings.passwordBook = book;
        saveSettings(this.context, this.appSettings).catch((error: BusinessError) => {
          console.warn(`invalidate ip password failed: ${error.code}`);
        });
      }
    }
    const hint = this.triedExplicitPlain
      ? `连接失败：${message}\n服务端可能已开启密码保护，请输入十六进制密钥后再连接。`
      : `连接失败：${message}\n密码可能不正确或已变更，请重新输入（服务器未开启密码保护请选「明文连接」）。`;
    this.openPasswordDialog(hint);
  }

  /** 密码框「连接」 */
  private submitPassword(): void {
    this.triedExplicitPlain = false;
    // 用户刚输入了新密码：重新走一遍验证，后续失败要能再次询问
    this.passwordVerified = false;
    this.noFrameWatchdogCount = 0;
    this.connectWithPassword(this.pwdInput.trim());
  }

  /** 密码框「明文连接」：服务器未开启 Password Protection 时用 */
  private submitPlain(): void {
    this.triedExplicitPlain = true;
    this.passwordVerified = false;
    this.noFrameWatchdogCount = 0;
    this.connectWithPassword('');
  }

  /** 密码框「返回」：不连接，回首页 */
  private cancelPassword(): void {
    this.pwdDialogVisible = false;
    this.awaitingPassword = false;
    this.leave();
  }

  private async reconnect(): Promise<void> {
    this.cancelAutoReconnect();
    this.autoReconnectAttempts = 0;
    const client = this.client;
    if (client !== undefined) {
      await client.disconnect();
      this.client = undefined;
    }
    this.stopAudio();
    this.statusText = '正在重连…';
    this.diagText = '';
    this.showOverlay = true;
    await this.startSession();
  }

  /**
   * 方向联动：窗口在横/竖之间切换时，把新方向（4=横 6=竖，与 APK 一致）
   * 发给服务器，Windows 端虚拟显示器据此调整画面方向。
   */
  private sendRotationIfNeeded(landscape: boolean): void {
    const client = this.client;
    if (client === undefined || !this.connected) {
      return;
    }
    if (this.sentRotationOnce && this.sentLandscape === landscape) {
      return;
    }
    this.sentLandscape = landscape;
    this.sentRotationOnce = true;
    client.sendRotation(landscape ? 4 : 6).catch((error: BusinessError) => {
      console.warn(`send rotation failed: ${error.code}`);
    });
    console.info(`rotation sent => ${landscape ? 4 : 6}`);
  }

  /** 暂停/继续：EvtDisplaySettings(6)，1=暂停 2=播放（服务器停止推流，省带宽） */
  private togglePause(): void {
    const client = this.client;
    if (client === undefined || !this.connected) {
      return;
    }
    this.paused = !this.paused;
    client.setStreamState(this.paused ? SdStreamState.Pause : SdStreamState.Play)
      .catch((error: BusinessError) => {
        console.warn(`send stream state failed: ${error.code}`);
      });
    this.statusText = this.paused ? '画面已暂停（服务器停止推流）' : '继续播放';
    this.showOverlay = true;
  }

  // ---------------- 画面渲染 ----------------

  /** 并发解码：同时最多处理 maxConcurrentDecodes 个分片，避免串行等待拖慢帧率 */
  private pumpDecodes(): void {
    while (this.activeDecodes < this.maxConcurrentDecodes && this.decodeQueue.length > 0) {
      const packet = this.decodeQueue.shift();
      if (packet === undefined) {
        break;
      }
      this.activeDecodes++;
      this.decodeAndDraw(packet);
    }
  }

  private releasePixelMap(pixelMap: image.PixelMap): void {
    pixelMap.release().then(() => {
    }).catch((error: BusinessError) => {
      console.warn(`release pixelmap failed: ${error.code}`);
    });
  }

  private async decodeAndDraw(packet: SdPacket): Promise<void> {
    try {
      // H.264：走原生 OH_AVCodec 解码（NAPI 模块 libh264dec.so），整帧上屏
      if (packet.compression === SdCompression.H264) {
        this.feedH264(packet);
        return;
      }
      if (packet.compression !== SdCompression.Mjpeg) {
        this.statusText = `服务器下发的压缩方式为 ${packet.compression}，本版本无法显示`;
        this.showOverlay = true;
        return;
      }
      const payload = packet.payload;
      if (payload.length === 0) {
        return;
      }

      const draw = this.getDrawSize();
      if (!(draw.w > 0) || !(draw.h > 0)) {
        this.diagText = '画布尺寸未就绪（canvasCtx.width/height=0）';
        this.showOverlay = true;
        this.statusText = '画布尚未完成布局，无法绘制';
        return;
      }

      let pixelMap: image.PixelMap | undefined = undefined;
      try {
        const buffer = payload.buffer as ArrayBuffer;
        const source = image.createImageSource(buffer);
        pixelMap = await source.createPixelMap();
        // 必须等 createPixelMap 完成后再释放 ImageSource，
        // 否则解码会拿到一个空 PixelMap，画上去就是黑屏（而且不报错）
        source.release().then(() => {
        }).catch((error: BusinessError) => {
          console.warn(`release image source failed: ${error.code}`);
        });
      } catch (error) {
        const err = error as BusinessError;
        this.decodeErrors++;
        this.statusText = `JPEG 解码失败（${err.code}）：${err.message}`;
        this.showOverlay = true;
        return;
      }

      if (pixelMap === undefined) {
        this.decodeErrors++;
        this.diagText = '解码返回空 PixelMap';
        this.showOverlay = true;
        this.statusText = 'JPEG 解码失败（空 PixelMap）';
        return;
      }

      // 整帧尺寸以"帧缓冲包头 width/height"为准（见 onFrame）。早于首包时兜底用本包值。
      const fw = this.frameWidth > 0 ? this.frameWidth : packet.width;
      const fh = this.frameHeight > 0 ? this.frameHeight : packet.height;
      // 等比适配（letterbox）：保持画面宽高比、居中铺到画布，避免拉伸变形。
      const fit = Math.min(draw.w / fw, draw.h / fh);
      const offX = (draw.w - fw * fit) / 2;
      const offY = (draw.h - fh * fit) / 2;
      const scaleX = fit;
      const scaleY = fit;
      const left = packet.rectLeft;
      const top = packet.rectTop;
      const right = packet.rectRight;
      const bottom = packet.rectBottom;
      // 整帧（full-frame）包：rect 覆盖整个屏幕，直接铺满适配区。
      const fullFrame = (left <= 0 && top <= 0 && right >= fw && bottom >= fh)
        || right <= left || bottom <= top;
      // 采样诊断：确认包头 width/height 到底是整帧还是条带尺寸，以及 rect 与 fit 是否自洽。
      if (this.stripsReceived % 300 === 0) {
        console.info(`[SD_FRM] pkt=${packet.width}x${packet.height} rect=${left},${top}-${right},${bottom}` +
          ` frag=${packet.fragment} draw=${draw.w}x${draw.h} frame=${fw}x${fh} fit=${fit.toFixed(3)}`);
      }

      // 直接增量绘制到主画布（与安卓 APK 的「持久 GL 表面累积 strip」模型一致）。
      // 关键：spacedesk MJPEG strip 是【增量协议】，服务端只下发变化区域的条带，
      // 画布必须持久累积、绝不能每帧清空，否则未更新区域丢失 → 画面割裂 / 残影。
      // 之前的 OffscreenCanvas + transferToImageBitmap 双缓冲是错的：
      // transferToImageBitmap 会「转移并清空」离屏内容，且每 12ms 一次全屏位图搬运
      // 在 60fps 明文高码率下开销极大（表现就是变卡）。
      // 每次 drawImage 在 UI 线程本身就是原子操作，屏幕不会看到「半片」，无需双缓冲。
      if (fullFrame) {
        this.canvasCtx.drawImage(pixelMap, offX, offY, fw * fit, fh * fit);
      } else {
        this.canvasCtx.drawImage(pixelMap,
          offX + left * scaleX, offY + top * scaleY,
          (right - left) * scaleX, (bottom - top) * scaleY);
      }
      this.releasePixelMap(pixelMap);
      // 每片都累计一次绘制。实测本机 MJPEG 流的 fragment 恒为 1（没有 0），
      // 所以不能用「fragment=0」当帧边界，否则统计恒为 0。
      // updateStats() 自带 1s 节流，这里每片调用不会每片重建 UI。
      this.markFrameShown();
    } finally {
      this.activeDecodes--;
      // 流控：每画完一片就回一次 ACK。实测服务器是“一个 ACK 放行一片”，
      // 按片回 ACK 后流的节奏严格等于渲染节奏，不会出现整帧堆积，
      // 也就不存在“队列满→丢片→某条横带不刷新”的问题。
      const client = this.client;
      if (client !== undefined) {
        client.sendFramebufferAck();
      }
      this.pumpDecodes();
    }
  }

  // 不再使用离屏双缓冲：增量协议下画布必须持久累积，见 decodeAndDraw 里的说明。

  /** 记录一次成功上屏：统计显示帧率，并在首帧时收起遮罩 */
  private markFrameShown(): void {
    this.drawnFrames++;
    this.updateStats();
    if (!this.firstFrameDrawn) {
      this.firstFrameDrawn = true;
      this.showOverlay = false;
      this.statusText = '画面已出';
    }
  }

  /** H.264 帧交给原生解码器，解码完成的整帧回调里直接贴满画布 */
  private feedH264(packet: SdPacket): void {
    if (this.h264Failed) {
      return;
    }
    if (this.h264 === undefined) {
      const decoder = new H264Decoder();
      const ok = decoder.init(packet.width, packet.height, (pixelMap: image.PixelMap) => {
        this.drawH264Frame(pixelMap);
      });
      if (!ok) {
        this.h264Failed = true;
        this.statusText = 'H.264 硬件解码初始化失败，请在 Windows 端把压缩方式改回 MJPEG';
        this.showOverlay = true;
        return;
      }
      this.h264 = decoder;
    }
    const payload = packet.payload;
    if (payload.length > 0) {
      this.h264.feed(payload.buffer as ArrayBuffer);
    }
  }

  private drawH264Frame(pixelMap: image.PixelMap): void {
    const draw = this.getDrawSize();
    if (!(draw.w > 0) || !(draw.h > 0)) {
      pixelMap.release();
      return;
    }
    // 与 MJPEG 一致的等比居中适配，避免拉伸变形。
    const fw = this.frameWidth > 0 ? this.frameWidth : draw.w;
    const fh = this.frameHeight > 0 ? this.frameHeight : draw.h;
    const fit = Math.min(draw.w / fw, draw.h / fh);
    const offX = (draw.w - fw * fit) / 2;
    const offY = (draw.h - fh * fit) / 2;
    this.canvasCtx.drawImage(pixelMap, offX, offY, fw * fit, fh * fit);
    pixelMap.release();
    this.drawnFrames++;
    this.updateStats();
    if (!this.firstFrameDrawn) {
      this.firstFrameDrawn = true;
      this.showOverlay = false;
      this.statusText = '画面已出';
    }
  }

  private updateStats(): void {
    const now = Date.now();
    if (now - this.statWindowStart < 1000) {
      return;
    }
    const fps = this.drawnFrames * 1000 / (now - this.statWindowStart);
    const ping = this.pingMs >= 0 ? ` · ${this.pingMs}ms` : '';
    // fragment 在本机流里恒为 1，拿不到真实帧边界，因此这里统计的是「绘制条带/秒」，不是帧率。
    this.statsText = `${this.frameWidth}×${this.frameHeight} · ${fps.toFixed(1)} 片/s${ping} · 丢帧 ${this.droppedFrames}`;
    this.diagText = `分片 ${this.stripsReceived} · 绘制 ${this.drawnFrames} · 解码失败 ${this.decodeErrors}` +
      ` · 压缩 ${this.lastCompression} · 画布 ${this.canvasCtx.width}×${this.canvasCtx.height}px` +
      ` · 帧 ${this.frameWidth}×${this.frameHeight} · 包 ${this.lastPktW}×${this.lastPktH} · frag ${this.lastFrag}` +
      ` · 队列 ${this.decodeQueue.length} · 矩形 ${this.lastRectText} · 直绘`;
    if (this.stripsReceived > 0 && this.drawnFrames === 0 && this.decodeErrors === 0) {
      this.statusText = '已收到分片但还没绘制出来（看下方诊断行）';
    }
    this.drawnFrames = 0;
    this.droppedFrames = 0;
    this.statWindowStart = now;
  }

  /** Area/Length 可能是数字，也可能是 "360vp" 之类的字符串，必须容错解析 */
  private toVp(value: Length): number {
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value === 'string') {
      const parsed = parseFloat(value);
      return isNaN(parsed) ? 0 : parsed;
    }
    return 0;
  }

  /** 保证 canvas 尺寸是有效正数，否则用 canvasCtx.width/height 兜底 */
  private refreshCanvasSize(): boolean {
    let width = this.vpWidth;
    let height = this.vpHeight;
    if (!(width > 0) || !(height > 0)) {
      try {
        width = this.canvasCtx.width;
        height = this.canvasCtx.height;
      } catch (error) {
        console.warn(`read canvas size failed: ${error}`);
      }
    }
    if (!(width > 0) || !(height > 0)) {
      return false;
    }
    this.vpWidth = width;
    this.vpHeight = height;
    return true;
  }

  /**
   * 绘制目标尺寸：必须用 Canvas 上下文自身的像素尺寸（canvasCtx.width/height），
   * 不能用 vpWidth/vpHeight（来自 onAreaChange，单位是 vp 虚拟像素）。
   * 原代码用 vp 尺寸去填 px 坐标的画布，导致画面只画在左上角一小块，
   * 其余区域是黑底 —— 表现就是“连上了但黑屏”。iOS 官方客户端没有这个坐标错配所以正常。
   * 这里统一回到画布原生坐标空间，无论底层 px/vp 语义如何都正确铺满。
   */
  private getDrawSize(): DrawSize {
    let w = this.canvasCtx.width;
    let h = this.canvasCtx.height;
    if (!(w > 0) || !(h > 0)) {
      w = this.vpWidth;
      h = this.vpHeight;
    }
    if (!(w > 0) || !(h > 0)) {
      w = this.frameWidth;
      h = this.frameHeight;
    }
    return { w, h };
  }

  // ---------------- 输入回传 ----------------

  private handleTouch(event: TouchEvent): void {
    const client = this.client;
    if (client === undefined || !this.connected || this.vpWidth <= 0) {
      return;
    }
    const touches = event.touches;
    if (touches.length === 0) {
      return;
    }
    // 鼠标模式（触控板）：点按=左键，双指滑动=滚轮，手势不走触摸通道
    if (this.appSettings.mouseMode) {
      this.handleTouchAsMouse(event, touches, client);
      return;
    }
    const scaleX = this.frameWidth / this.vpWidth;
    const scaleY = this.frameHeight / this.vpHeight;
    const first = touches[0];
    const x = first.x * scaleX;
    const y = first.y * scaleY;

    let action: SdTouchAction = SdTouchAction.Move;
    if (event.type === TouchType.Down) {
      action = SdTouchAction.Down;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      action = SdTouchAction.Up;
    }

    const points: SdTouchPoint[] = [];
    if (action !== SdTouchAction.Up) {
      for (let i = 0; i < touches.length && i < 7; i++) {
        points.push(new SdTouchPoint(touches[i].x * scaleX, touches[i].y * scaleY, i, action));
      }
    }
    client.sendTouch(x, y, this.frameWidth, this.frameHeight, action, points);
  }

  /**
   * 鼠标模式（触控板），对应安卓客户端的鼠标输入，走 EvtMouse(type=10)：
   *   - 单指点按（移动 < 10vp 且 < 400ms）→ 左键单击（flags 8 按下 / 16 抬起，逆向报告 8.3 节确认值）
   *   - 双指滑动 → 滚轮（offset 16，±120 一格；与 Windows 触控板默认一致：手指下滑页面下滚）
   *   - 坐标按虚拟显示器像素绝对值上报（offset 8/12）
   * 协议未确认的部分（拖拽按住、右键 flags）不发送，避免未定义报文导致服务器断开。
   */
  private handleTouchAsMouse(event: TouchEvent, touches: TouchObject[], client: SdClient): void {
    const scaleX = this.frameWidth / this.vpWidth;
    const scaleY = this.frameHeight / this.vpHeight;

    if (touches.length >= 2) {
      // 双指点按（快速、无滚动）= 右键；双指滑动 = 滚轮
      if (event.type === TouchType.Down) {
        this.twoFingerDownAt = Date.now();
        this.twoFingerMoved = false;
        this.wheelAccum = 0;
      }
      if (event.type === TouchType.Move) {
        const midX = (touches[0].x + touches[1].x) / 2;
        const midY = (touches[0].y + touches[1].y) / 2;
        if (this.wheelTracking) {
          this.wheelAccum += midY - this.wheelLastY;
          if (Math.abs(this.wheelAccum) > 20) {
            this.twoFingerMoved = true;
          }
          // 每 30vp 发一格滚动
          while (Math.abs(this.wheelAccum) >= 30) {
            const down = this.wheelAccum > 0;
            const step = down ? -120 : 120;
            this.wheelAccum -= down ? 30 : -30;
            client.sendMouse(midX * scaleX, midY * scaleY, SdMouseButton.None, step)
              .catch((error: BusinessError) => {
                console.warn(`send wheel failed: ${error.code}`);
              });
          }
        }
        this.wheelLastY = midY;
        this.wheelTracking = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (!this.twoFingerMoved && this.twoFingerDownAt > 0
          && Date.now() - this.twoFingerDownAt < 400 && touches.length <= 2) {
          // 双指点按 = 右键单击（flags 32/64 为推算值）
          const mx = touches[0].x * scaleX;
          const my = touches[0].y * scaleY;
          client.sendMouse(mx, my, SdMouseButton.RightDown, 0)
            .then(() => client.sendMouse(mx, my, SdMouseButton.RightUp, 0))
            .catch((error: BusinessError) => {
              console.warn(`send right click failed: ${error.code}`);
            });
        }
        this.twoFingerDownAt = 0;
        this.wheelTracking = false;
        this.wheelAccum = 0;
      }
      return;
    }

    // 单指：点按 = 左键单击；按住拖动 = 左键拖拽
    const first = touches[0];
    const x = first.x * scaleX;
    const y = first.y * scaleY;
    if (event.type === TouchType.Down) {
      this.tapDownAt = Date.now();
      this.tapDownVpX = first.x;
      this.tapDownVpY = first.y;
      this.tapMoved = false;
      this.dragging = false;
      this.wheelTracking = false;
    } else if (event.type === TouchType.Move) {
      const dx = first.x - this.tapDownVpX;
      const dy = first.y - this.tapDownVpY;
      if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
        this.tapMoved = true;
      }
      const now = Date.now();
      if (this.tapMoved && !this.dragging && now - this.tapDownAt > 120) {
        // 开始拖拽：当前位置按下左键（按住状态由服务器维护，后续移动 flags=0）
        this.dragging = true;
        this.lastMouseMoveAt = now;
        client.sendMouse(x, y, SdMouseButton.LeftDown, 0)
          .catch((error: BusinessError) => {
            console.warn(`send drag down failed: ${error.code}`);
          });
      } else if (this.dragging && now - this.lastMouseMoveAt >= 33) {
        // 拖拽移动节流到约 30Hz
        this.lastMouseMoveAt = now;
        client.sendMouse(x, y, SdMouseButton.None, 0)
          .catch((error: BusinessError) => {
            console.warn(`send drag move failed: ${error.code}`);
          });
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.dragging) {
        this.dragging = false;
        client.sendMouse(x, y, SdMouseButton.LeftUp, 0)
          .catch((error: BusinessError) => {
            console.warn(`send drag up failed: ${error.code}`);
          });
      } else if (!this.tapMoved && Date.now() - this.tapDownAt < 400) {
        client.sendMouse(x, y, SdMouseButton.LeftDown, 0)
          .then(() => client.sendMouse(x, y, SdMouseButton.LeftUp, 0))
          .catch((error: BusinessError) => {
            console.warn(`send click failed: ${error.code}`);
          });
      }
      this.tapMoved = false;
    }
  }

  private handleKey(event: KeyEvent): void {
    const client = this.client;
    if (client === undefined || !this.connected) {
      return;
    }
    // 系统返回键留给鸿蒙自己处理，不要发给 Windows
    if (event.keyCode === KeyCode.KEYCODE_BACK) {
      return;
    }
    // 1) 可打印字符按 Unicode 透传（动作 = Text），兼容中文输入法上屏结果
    if (event.type === KeyType.Down && event.keyText !== undefined && event.keyText.length === 1) {
      const code = event.keyText.charCodeAt(0);
      if (code >= 32 && code !== 127) {
        client.sendChar(code);
        return;
      }
    }
    // 2) 方向键 / 功能键 / 修饰键按“按下-抬起”上报 Android keyCode
    const serverCode = toServerKeyCode(event.keyCode);
    if (serverCode > 0) {
      if (event.type === KeyType.Down) {
        client.sendKey(serverCode, SdKeyAction.Down);
      } else if (event.type === KeyType.Up) {
        client.sendKey(serverCode, SdKeyAction.Up);
      }
    }
  }

  @Builder
  overlayBar() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(13)
          .height(32)
          .backgroundColor('#33FFFFFF')
          .onClick(() => {
            this.leave();
          })
        Button('重连')
          .fontSize(13)
          .height(32)
          .margin({ left: 8 })
          .backgroundColor('#33FFFFFF')
          .onClick(() => {
            this.reconnect();
          })
        Button(this.paused ? '继续' : '暂停')
          .fontSize(13)
          .height(32)
          .margin({ left: 8 })
          .backgroundColor(this.paused ? '#3399FF66' : '#33FFFFFF')
          .onClick(() => {
            this.togglePause();
          })
        Text(this.statusText.length > 0 ? this.statusText : this.params.name)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .margin({ left: 10, right: 10 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.appSettings.showStats) {
          Text(this.statsText)
            .fontSize(11)
            .fontColor('#B8C2D4')
        }
      }
      .width('100%')

      if (this.diagText.length > 0) {
        Text(this.diagText)
          .fontSize(10)
          .fontColor('#8FA0B8')
          .width('100%')
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.audioText.length > 0) {
        Text(`音频：${this.audioText}`)
          .fontSize(10)
          .fontColor('#C9A86A')
          .width('100%')
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#CC0E1118')
  }

  // ---------------- 虚拟按键条 ----------------

  private sendKeyCode(hosKeyCode: number, down: boolean): void {
    const client = this.client;
    if (client === undefined || !this.connected) {
      return;
    }
    const serverCode = toServerKeyCode(hosKeyCode);
    if (serverCode > 0) {
      client.sendKey(serverCode, down ? SdKeyAction.Down : SdKeyAction.Up)
        .catch((error: BusinessError) => {
          console.warn(`send virtual key failed: ${error.code}`);
        });
    }
  }

  /** 点按型按键：按下立即抬起 */
  private tapVirtualKey(hosKeyCode: number): void {
    this.sendKeyCode(hosKeyCode, true);
    this.sendKeyCode(hosKeyCode, false);
  }

  /**
   * 锁定型修饰键：点一下按下并保持（高亮），再点抬起。
   * 锁定 Ctrl/Alt 后再点画面，即组成 Ctrl+点击 / Alt+点击 等组合操作。
   */
  private toggleLockKey(hosKeyCode: number, kind: string): void {
    let down = false;
    if (kind === 'ctrl') {
      this.lockCtrl = !this.lockCtrl;
      down = this.lockCtrl;
    } else if (kind === 'alt') {
      this.lockAlt = !this.lockAlt;
      down = this.lockAlt;
    } else if (kind === 'shift') {
      this.lockShift = !this.lockShift;
      down = this.lockShift;
    } else if (kind === 'meta') {
      this.lockMeta = !this.lockMeta;
      down = this.lockMeta;
    }
    this.sendKeyCode(hosKeyCode, down);
  }

  @Builder
  keyBarButton(label: string, active: boolean, action: () => void) {
    Button(label)
      .fontSize(12)
      .height(30)
      .padding({ left: 12, right: 12 })
      .backgroundColor(active ? '#2E6BE6' : '#33FFFFFF')
      .fontColor('#FFFFFF')
      .onClick(() => action())
  }

  @Builder
  virtualKeyBar() {
    Column() {
      Scroll() {
        Row() {
          this.keyBarButton('Esc', false, (): void => this.tapVirtualKey(2070))
          this.keyBarButton('Tab', false, (): void => this.tapVirtualKey(2049))
          this.keyBarButton('Win', this.lockMeta, (): void => this.toggleLockKey(2076, 'meta'))
          this.keyBarButton('Ctrl', this.lockCtrl, (): void => this.toggleLockKey(2072, 'ctrl'))
          this.keyBarButton('Alt', this.lockAlt, (): void => this.toggleLockKey(2045, 'alt'))
          this.keyBarButton('Shift', this.lockShift, (): void => this.toggleLockKey(2047, 'shift'))
          this.keyBarButton('Enter', false, (): void => this.tapVirtualKey(2054))
          this.keyBarButton('Del', false, (): void => this.tapVirtualKey(2055))
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      Scroll() {
        Row() {
          this.keyBarButton('←', false, (): void => this.tapVirtualKey(2014))
          this.keyBarButton('↑', false, (): void => this.tapVirtualKey(2012))
          this.keyBarButton('↓', false, (): void => this.tapVirtualKey(2013))
          this.keyBarButton('→', false, (): void => this.tapVirtualKey(2015))
          this.keyBarButton('Home', false, (): void => this.tapVirtualKey(2081))
          this.keyBarButton('End', false, (): void => this.tapVirtualKey(2082))
          this.keyBarButton('PgUp', false, (): void => this.tapVirtualKey(2068))
          this.keyBarButton('PgDn', false, (): void => this.tapVirtualKey(2069))
          this.keyBarButton('收起', false, (): void => {
            this.showKeyBar = false;
          })
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 10 })
    .backgroundColor('#CC0E1118')
  }

  /**
   * 连接时按 IP 询问密码（无参数 @Builder，直接读 @State，保证刷新）。
   * 两个必须同时满足的约束：
   *  ① 根节点不能用 HitTestMode.Block —— 它「自身响应并阻塞子节点命中测试」，
   *     会把 TextInput / 三个 Button 全部挡住，弹窗可见却完全点不动。
   *  ② 输入法弹出会把应用窗口压到约 500px（横屏实测 2848x503），
   *     内容必须放进 Scroll，否则按钮被裁到屏外，同样够不到。
   */
  @Builder
  passwordDialog() {
    Stack() {
      Scroll() {
        Column() {
          Column() {
            Text('连接密码')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .width('100%')
            Text(`服务器 ${this.pwdIpLabel}:${this.params.port}`)
              .fontSize(13)
              .fontColor('#9AA6B8')
              .margin({ top: 4 })
              .width('100%')
            if (this.pwdHint.length > 0) {
              Text(this.pwdHint)
                .fontSize(13)
                .fontColor('#FFB26A')
                .lineHeight(19)
                .margin({ top: 8 })
                .width('100%')
            }
            Text('输入电脑端 Driver Console 显示的十六进制密钥。仅按当前 IP 保存在本机，连接成功后才记住。')
              .fontSize(12)
              .fontColor('#9AA6B8')
              .lineHeight(18)
              .margin({ top: 8 })
              .width('100%')
            TextInput({ placeholder: '十六进制密钥，如 39652E86', text: this.pwdInput })
              .type(InputType.Password)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .placeholderColor('#6B7787')
              .backgroundColor('#1B2330')
              .height(42)
              .margin({ top: 10 })
              .width('100%')
              .onChange((v: string) => {
                this.pwdInput = v;
              })
              // 键盘「完成/回车」直接连接：键盘遮挡按钮时的兜底
              .onSubmit(() => {
                this.submitPassword();
              })
            Row() {
              Button('明文连接')
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .backgroundColor('#334A5C')
                .fontColor('#C9D6E5')
                .onClick(() => {
                  this.submitPlain();
                })
              Button('连接')
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .margin({ left: 8 })
                .backgroundColor('#2E6BE6')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.submitPassword();
                })
            }
            .width('100%')
            .margin({ top: 12 })
            Button('返回首页')
              .fontSize(13)
              .height(34)
              .width('100%')
              .margin({ top: 6 })
              .backgroundColor('#00000000')
              .fontColor('#8A97A9')
              .onClick(() => {
                this.cancelPassword();
              })
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor('#232C3A')
          .borderWidth(1)
          .borderColor('#3A4658')
          .onClick(() => {
          })
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Center)
      }
      .scrollBar(BarState.Off)
      .width('86%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Default)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#CC0A0E14')
    .hitTestBehavior(HitTestMode.Default)
    .onClick(() => {
    })
  }

  private async leave(): Promise<void> {
    this.userClosing = true;
    this.cancelAutoReconnect();
    this.clearFirstFrameTimer();
    const client = this.client;
    if (client !== undefined) {
      await client.disconnect();
    }
    router.back();
  }

  build() {
    Stack() {
      Canvas(this.canvasCtx)
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
        .focusable(true)
        .defaultFocus(true)
        .onReady(() => {
          this.canvasReady = true;
          const draw = this.getDrawSize();
          this.canvasCtx.fillStyle = '#000000';
          this.canvasCtx.fillRect(0, 0, draw.w, draw.h);
        })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const w = this.toVp(newValue.width);
          const h = this.toVp(newValue.height);
          if (w > 0 && h > 0) {
            const changed = this.vpWidth !== w || this.vpHeight !== h;
            this.vpWidth = w;
            this.vpHeight = h;
            // 窗口横竖切换时同步旋转报文给服务器
            this.sendRotationIfNeeded(w >= h);
            // 仅在尺寸真正变化时清屏：增量协议下画布内容必须持久累积，
            // 无关的 onAreaChange 反复清黑会造成画面割裂 / 黑块。
            if (changed) {
              const changedDraw = this.getDrawSize();
              this.canvasCtx.fillStyle = '#000000';
              this.canvasCtx.fillRect(0, 0, changedDraw.w, changedDraw.h);
            }
          }
        })
        .onTouch((event: TouchEvent) => {
          this.handleTouch(event);
        })
        .onKeyEvent((event: KeyEvent) => {
          this.handleKey(event);
        })

      Column() {
        if (this.showOverlay) {
          this.overlayBar()
        } else {
          Blank()
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .hitTestBehavior(HitTestMode.Transparent)

      // 虚拟按键条（底部）
      Column() {
        Blank()
        if (this.showKeyBar) {
          this.virtualKeyBar()
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)

      // 右下角控制按钮
      Column() {
        Blank()
        Row() {
          Button('键盘')
            .fontSize(11)
            .height(26)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.showKeyBar ? '#2E6BE6' : '#66000000')
            .onClick(() => {
              this.showKeyBar = !this.showKeyBar;
            })
          Button(this.showOverlay ? '收起' : '菜单')
            .fontSize(11)
            .height(26)
            .padding({ left: 8, right: 8 })
            .margin({ left: 8 })
            .backgroundColor('#66000000')
            .onClick(() => {
              this.showOverlay = !this.showOverlay;
            })
        }
        .margin({ right: 14, bottom: 14 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)

      // 连接时的密码输入层（最上层，覆盖画布与所有控件）
      if (this.pwdDialogVisible) {
        this.passwordDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  /** 系统返回键：连接中先确认，防误触断开 */
  onBackPress(): boolean {
    if (this.pwdDialogVisible) {
      this.cancelPassword();
      return true;
    }
    if (!this.connected) {
      return false;
    }
    this.confirmLeave();
    return true;
  }

  private async confirmLeave(): Promise<void> {
    try {
      const result = await promptAction.showDialog({
        title: '断开连接',
        message: '确定断开并返回主页吗？',
        buttons: [
          { text: '取消', color: '#6B7787' },
          { text: '断开', color: '#0A59F7' }
        ]
      });
      if (result.index === 1) {
        this.leave();
      }
    } catch (error) {
      // 用户取消/对话框异常：留在当前页
    }
  }
}
