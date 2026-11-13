/**
 * 全屏投屏页：画面显示 + 缩放平移 + 鼠标/触摸双模式 + 全键软键盘 + 悬浮控制
 */
import { router, promptAction, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { settings } from '../model/SettingsModel';
import {
  connectionService, SessionState, SessionCallbacks, ConnectOptions
} from '../service/ConnectionService';
import { audioService } from '../service/AudioService';
import { Compression, IdentificationOptions, NET_PORT } from '../common/Protocol';
import {
  MouseAction, TouchAction, KeyAction, MouseButton, KeyModifier,
  PointerSample, VKey, AudioChunk
} from '../common/ProtocolEx';
import { s } from '../common/Res';
import {
  init as h264Init, push as h264Push, poll as h264Poll,
  release as h264Release, DecodedFrame
} from 'libscreenmirror.so';

// 半模态弹层状态机：同一节点只允许绑定一个 bindSheet，多个会互相冲突（后绑吞先绑）
const SHEET_NONE: number = 0;
const SHEET_KEYBOARD: number = 1;
const SHEET_ROTATION: number = 2;
const SHEET_RESOLUTION: number = 3;

interface DisplayParams {
  host: string;
  port: number;
  name: string;
  encrypted: boolean;
  password: string;
}

/** 软键盘按键定义 */
interface KeyDef {
  label: string;
  code: number;
  weight: number;
}

const KEY_ROWS: KeyDef[][] = [
  [
    { label: 'Esc', code: VKey.ESC, weight: 1 }, { label: 'F1', code: VKey.F1, weight: 1 },
    { label: 'F2', code: 113, weight: 1 }, { label: 'F3', code: 114, weight: 1 },
    { label: 'F4', code: 115, weight: 1 }, { label: 'F5', code: 116, weight: 1 },
    { label: 'F6', code: 117, weight: 1 }, { label: 'F12', code: VKey.F12, weight: 1 }
  ],
  [
    { label: 'Tab', code: VKey.TAB, weight: 1 }, { label: '←', code: VKey.LEFT, weight: 1 },
    { label: '↑', code: VKey.UP, weight: 1 }, { label: '↓', code: VKey.DOWN, weight: 1 },
    { label: '→', code: VKey.RIGHT, weight: 1 }, { label: 'Home', code: VKey.HOME, weight: 1 },
    { label: 'End', code: VKey.END, weight: 1 }, { label: 'Del', code: VKey.DELETE, weight: 1 }
  ],
  [
    { label: 'Win', code: VKey.LWIN, weight: 1 }, { label: 'PgUp', code: VKey.PAGEUP, weight: 1 },
    { label: 'PgDn', code: VKey.PAGEDOWN, weight: 1 }, { label: 'Ins', code: VKey.INSERT, weight: 1 },
    { label: '空格', code: VKey.SPACE, weight: 1 }, { label: '退格', code: VKey.BACKSPACE, weight: 1 },
    { label: '回车', code: VKey.ENTER, weight: 1 }
  ]
];

@Entry
@Component
struct DisplayPage {
  @State frame: image.PixelMap | undefined = undefined;
  @State status: string = '';
  @State statsText: string = '';
  @State dockPanel: number = 0;         // 0=收起 1=操作 2=显示（参照真APK右侧图标坞布局）
  @State activeSheet: number = SHEET_NONE;
  @State keyboardText: string = '';
  @State pointerMode: number = 0;       // 0=鼠标 1=触摸
  @State zoom: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;
  @State shiftOn: boolean = false;
  @State ctrlOn: boolean = false;
  @State altOn: boolean = false;
  @State winOn: boolean = false;
  @State viewW: number = 1;
  @State viewH: number = 1;
  @State remoteW: number = 0;
  @State remoteH: number = 0;
  @State rotation: number = 0;
  @State resW: string = '1920';
  @State resH: string = '1080';
  @State audioBytes: number = 0;
  @State displayFill: boolean = true;   // true=拉伸铺满 false=自适应等比
  @State dotX: number = -100;
  @State dotY: number = -100;
  @State dotShow: boolean = false;

  private host: string = '';
  private port: number = NET_PORT;
  private name: string = '';
  private lastPinch: number = 0;
  private lastPanX: number = 0;
  private lastPanY: number = 0;
  private buttonsDown: number = MouseButton.NONE;
  private frozen: boolean = false;
  private h264Ready: boolean = false;
  private pollTimer: number = -1;
  private dotTimer: number = -1;

  aboutToAppear(): void {
    const p = router.getParams() as DisplayParams;
    if (p === undefined || p.host === undefined) {
      promptAction.showToast({ message: s($r('app.string.err_invalid_ip')) });
      router.back();
      return;
    }
    this.host = p.host;
    this.port = p.port > 0 ? p.port : NET_PORT;
    this.name = p.name.length > 0 ? p.name : p.host;
    this.pointerMode = settings.getNumber('harmony_pointer_mode', 0);
    this.resW = String(settings.getNumber('harmony_resolution_width', 1920));
    this.resH = String(settings.getNumber('harmony_resolution_height', 1080));
    this.zoom = 1;

    if (p.encrypted) {
      promptAction.showToast({ message: '该主机要求 TLS-PSK 加密会话，当前版本将以明文模式尝试连接' });
    }

    const opt: IdentificationOptions = {
      instanceId: settings.getInstanceId(),
      deviceName: settings.getString('harmony_device_name', 'HarmonyOS Phone'),
      compression: settings.getCompression() === Compression.CHOOSE_BEST
        ? Compression.MJPEG : settings.getCompression(),
      fps: settings.getFps(),
      colorDepth: settings.getColorDepth()
    };

    const connOpt: ConnectOptions = {
      password: p.password.length > 0 ? p.password : '',
      audioEnabled: settings.getBool('key_audio', true),
      autoReconnect: settings.getBool('harmony_auto_reconnect', true),
      watchdogMs: settings.getConnectTimeout(),
      pingIntervalMs: 5000,
      quality: settings.getQuality(),
      width: Number.parseInt(this.resW, 10),
      height: Number.parseInt(this.resH, 10),
      rotation: this.rotation
    };
    audioService.setEnabled(connOpt.audioEnabled);
    audioService.setVolume(settings.getNumber('harmony_audio_volume', 100) / 100);

    const callbacks: SessionCallbacks = {
      onState: (state: SessionState, detail: string): void => {
        this.status = this.stateText(state, detail);
      },
      onFrame: (pixelMap: image.PixelMap, frameBytes: number): void => {
        if (!this.frozen) {
          this.frame = pixelMap;
        }
      },
      onH264Data: (data: ArrayBuffer): void => {
        if (this.h264Ready) {
          h264Push(data);
        } else if (this.statsText.indexOf('H.264') < 0) {
          this.statsText = 'H.264 解码器未就绪，请切换到 MJPEG 编码';
        }
      },
      onMessage: (text: string): void => {
        promptAction.showToast({ message: text });
      },
      onDisconnected: (reason: string): void => {
        promptAction.showToast({ message: reason });
      },
      onStats: (fps: number, kbps: number, w: number, h: number): void => {
        this.remoteW = w;
        this.remoteH = h;
        this.statsText = `${fps} 帧/秒  ·  ${kbps} KB/s  ·  ` +
          `${w > 0 ? `${w}×${h}` : '自适应'}  ·  ` +
          `${s($r('app.string.about_connected_time'))}${connectionService.getConnectedSeconds()}s  ·  ` +
          `输入${connectionService.inputCount}`;
      },
      onRotation: (degrees: number): void => {
        this.rotation = degrees;
        this.applyOrientation(degrees);
      },
      onDisplaySettings: (width: number, height: number): void => {
        this.remoteW = width;
        this.remoteH = height;
      },
      onAudio: (chunk: AudioChunk): void => {
        this.audioBytes += chunk.pcm.byteLength;
      }
    };

    connectionService.connect(this.host, this.port, opt, callbacks, connOpt);
    if (opt.compression === Compression.H264) {
      this.startH264Decoder();
    }
    this.setFullscreen(true);
  }

  aboutToDisappear(): void {
    this.frozen = false;
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.h264Ready) {
      h264Release();
      this.h264Ready = false;
    }
    connectionService.disconnect();
    this.setFullscreen(false);
  }

  /** OH_AVCodec 解码器：初始化 + 定时轮询 RGBA 帧上屏 */
  private startH264Decoder(): void {
    const w: number = Number.parseInt(this.resW, 10);
    const h: number = Number.parseInt(this.resH, 10);
    try {
      this.h264Ready = h264Init(Number.isNaN(w) ? 1920 : w, Number.isNaN(h) ? 1080 : h);
    } catch (e) {
      this.h264Ready = false;
    }
    if (!this.h264Ready) {
      promptAction.showToast({ message: 'H.264 原生解码器不可用，建议在设置里改用 MJPEG' });
      return;
    }
    this.pollTimer = setInterval((): void => {
      if (!this.h264Ready || this.frozen) {
        return;
      }
      let f: DecodedFrame;
      try {
        f = h264Poll();
      } catch (e) {
        return;
      }
      if (f.data.byteLength === 0 || f.width <= 0 || f.height <= 0) {
        return;
      }
      if (f.data.byteLength < f.width * f.height * 4) {
        return;
      }
      try {
        const opts: image.InitializationOptions = {
          size: { height: f.height, width: f.width },
          pixelFormat: image.PixelMapFormat.RGBA_8888,
          alphaType: image.AlphaType.OPAQUE,
          editable: false
        };
        this.frame = image.createPixelMapSync(f.data, opts);
      } catch (e) {
        // 单帧失败不影响后续
      }
    }, 16);
  }

  private setFullscreen(on: boolean): void {
    window.getLastWindow(getContext()).then((win: window.Window): void => {
      win.setWindowLayoutFullScreen(on);
      win.setWindowKeepScreenOn(on);
      if (on && settings.getBool('harmony_landscape', true)) {
        win.setPreferredOrientation(window.Orientation.LANDSCAPE);
      } else {
        win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
      }
    }).catch((): void => {});
  }

  private applyOrientation(degrees: number): void {
    const target: window.Orientation = (degrees === 90 || degrees === 270)
      ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT;
    window.getLastWindow(getContext()).then((win: window.Window): void => {
      win.setPreferredOrientation(target);
      connectionService.requestRotation(degrees);
    }).catch((): void => {});
  }

  private stateText(state: SessionState, detail: string): string {
    switch (state) {
      case SessionState.CONNECTING:
        return s($r('app.string.status_connecting')).replace('%s', detail);
      case SessionState.CONNECTED: return s($r('app.string.status_connected'));
      case SessionState.DISPLAY_OFF: return s($r('app.string.status_display_off'));
      case SessionState.DISCONNECTING: return s($r('app.string.status_disconnecting'));
      case SessionState.DISCONNECTED: return s($r('app.string.status_disconnected'));
      case SessionState.FAILED: return s($r('app.string.status_failed'));
      case SessionState.RECONNECTING: return `正在重连（${detail}）`;
      default: return s($r('app.string.status_idle'));
    }
  }

  private modifiers(): number {
    let m: number = KeyModifier.NONE;
    if (this.shiftOn) { m |= KeyModifier.SHIFT; }
    if (this.ctrlOn) { m |= KeyModifier.CTRL; }
    if (this.altOn) { m |= KeyModifier.ALT; }
    if (this.winOn) { m |= KeyModifier.META; }
    return m;
  }

  /** 把屏幕坐标反变换成远端归一化坐标 */
  private toRemote(sx: number, sy: number): number[] {
    const cx: number = this.viewW / 2;
    const cy: number = this.viewH / 2;
    const x: number = ((sx - cx - this.panX) / this.zoom + cx) / this.viewW;
    const y: number = ((sy - cy - this.panY) / this.zoom + cy) / this.viewH;
    return [Math.max(0, Math.min(1, x)), Math.max(0, Math.min(1, y))];
  }

  private onPointerEvent(event: TouchEvent): void {
    const list: TouchObject[] = event.touches.length > 0
      ? event.touches : event.changedTouches;
    if (list.length === 0) {
      return;
    }
    // 双指：缩放 + 平移本地视图，不回传触摸
    if (list.length >= 2) {
      const dx: number = list[0].x - list[1].x;
      const dy: number = list[0].y - list[1].y;
      const dist: number = Math.sqrt(dx * dx + dy * dy);
      const midX: number = (list[0].x + list[1].x) / 2;
      const midY: number = (list[0].y + list[1].y) / 2;
      if (this.lastPinch > 0) {
        const next: number = Math.max(1, Math.min(5, this.zoom * (dist / this.lastPinch)));
        this.zoom = next;
        this.panX += midX - this.lastPanX;
        this.panY += midY - this.lastPanY;
      }
      this.lastPinch = dist;
      this.lastPanX = midX;
      this.lastPanY = midY;
      return;
    }
    this.lastPinch = 0;

    const t: TouchObject = list[0];
    // 本地触摸反馈点（服务端不把光标渲染进视频流，需本地提示）
    this.dotX = t.x;
    this.dotY = t.y;
    this.dotShow = true;
    if (this.dotTimer >= 0) {
      clearTimeout(this.dotTimer);
    }
    this.dotTimer = setTimeout((): void => {
      this.dotShow = false;
    }, 350);
    const c: number[] = this.toRemote(t.x, t.y);
    const action: TouchAction = event.type === TouchType.Down ? TouchAction.DOWN
      : event.type === TouchType.Up ? TouchAction.UP : TouchAction.MOVE;

    if (this.pointerMode === 1) {
      const pts: PointerSample[] = [];
      for (const item of list) {
        const cc: number[] = this.toRemote(item.x, item.y);
        pts.push({ id: item.id, x: cc[0], y: cc[1], pressure: 1, radius: 0 });
      }
      connectionService.sendTouch(action, pts);
      return;
    }

    // 鼠标模式
    if (event.type === TouchType.Down) {
      this.buttonsDown = MouseButton.LEFT;
      connectionService.sendMouse(MouseAction.DOWN, c[0], c[1], this.buttonsDown, 0);
    } else if (event.type === TouchType.Up) {
      connectionService.sendMouse(MouseAction.UP, c[0], c[1], MouseButton.NONE, 0);
      this.buttonsDown = MouseButton.NONE;
    } else {
      connectionService.sendMouse(MouseAction.MOVE, c[0], c[1], this.buttonsDown, 0);
    }
  }

  private sendKey(code: number): void {
    const m: number = this.modifiers();
    connectionService.sendKeyboard(KeyAction.DOWN, code, code, m, 0);
    connectionService.sendKeyboard(KeyAction.UP, code, code, m, 0);
  }

  private sendText(): void {
    const m: number = this.modifiers();
    for (let i: number = 0; i < this.keyboardText.length; i++) {
      const ch: number = this.keyboardText.charCodeAt(i);
      connectionService.sendKeyboard(KeyAction.CHAR, 0, ch, m, 0);
    }
    this.keyboardText = '';
  }

  private async goBack(): Promise<void> {
    const res = await promptAction.showDialog({
      title: s($r('app.string.dlg_disconnect_title')),
      message: s($r('app.string.dlg_disconnect_text')),
      buttons: [
        { text: s($r('app.string.btn_cancel')), color: '#6B7787' },
        { text: s($r('app.string.btn_ok')), color: '#0A59F7' }
      ]
    });
    if (res.index === 1) {
      router.back();
    }
  }

  onBackPress(): boolean {
    this.goBack();
    return true;
  }

  @Builder
  ToolButton(label: string, bg: string, action: () => void) {
    Button(label).fontSize(12).height(34).layoutWeight(1)
      .backgroundColor(bg).fontColor(Color.White)
      .onClick(() => action())
  }

  /** 右侧图标坞圆形按钮（图标+文字标签） */
  @Builder
  DockButton(label: string, glyph: string, bg: string, active: boolean, action: () => void) {
    Column() {
      Button() {
        Text(glyph).fontSize(17).fontColor(Color.White)
      }
      .width(46).height(46).borderRadius(23)
      .backgroundColor(active ? $r('app.color.primary') : bg)
      .border({ width: 1, color: '#33FFFFFF' })
      .onClick(() => action())
      Text(label).fontSize(10).fontColor('#FFE0E6EE').margin({ top: 3 })
    }
    .margin({ bottom: 12 })
  }

  /** 操作面板：指针模式 / 鼠标按键 / 滚轮 / 冻结 */
  @Builder
  OpPanel() {
    Column() {
      Text('操作').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Row() {
        this.ToolButton(this.pointerMode === 0 ? '模式：鼠标' : '模式：触摸', '#FF3B5A80', () => {
          this.pointerMode = this.pointerMode === 0 ? 1 : 0;
          settings.putNumber('harmony_pointer_mode', this.pointerMode);
        })
        this.ToolButton('左键', '#FF3B5A80', () => {
          connectionService.sendMouse(MouseAction.DOWN, 0.5, 0.5, MouseButton.LEFT, 0);
          connectionService.sendMouse(MouseAction.UP, 0.5, 0.5, MouseButton.NONE, 0);
        })
        this.ToolButton('右键', '#FF3B5A80', () => {
          connectionService.sendMouse(MouseAction.DOWN, 0.5, 0.5, MouseButton.RIGHT, 0);
          connectionService.sendMouse(MouseAction.UP, 0.5, 0.5, MouseButton.NONE, 0);
        })
      }.width('100%').margin({ top: 8 })
      Row() {
        this.ToolButton('滚轮 ↑', '#FF3B5A80', () => {
          connectionService.sendMouse(MouseAction.SCROLL, 0.5, 0.5, MouseButton.NONE, 120);
        })
        this.ToolButton('滚轮 ↓', '#FF3B5A80', () => {
          connectionService.sendMouse(MouseAction.SCROLL, 0.5, 0.5, MouseButton.NONE, -120);
        })
      }.width('100%').margin({ top: 6 })
      Row() {
        this.ToolButton(this.frozen ? '继续画面' : '冻结画面', '#FF3B5A80', () => {
          this.frozen = !this.frozen;
        })
        this.ToolButton('显示设置', '#FF3B5A80', () => {
          this.dockPanel = 0;
          router.pushUrl({ url: 'pages/SettingsPage' });
        })
      }.width('100%').margin({ top: 6 })
    }
    .padding(12).borderRadius(14)
    .backgroundColor($r('app.color.toolbar_background'))
    .constraintSize({ maxWidth: '76%' })
    .margin({ left: 8 })
  }

  /** 显示面板：铺满/适应 / 缩放复位 / 旋转 / 分辨率 */
  @Builder
  DisplayPanel() {
    Column() {
      Text('显示').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Row() {
        this.ToolButton(this.displayFill ? '显示：铺满' : '显示：适应', '#FF3B5A80', () => {
          this.displayFill = !this.displayFill;
        })
        this.ToolButton('复位视图', '#FF3B5A80', () => {
          this.zoom = 1; this.panX = 0; this.panY = 0;
        })
      }.width('100%').margin({ top: 8 })
      Text('旋转').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
        .margin({ top: 8 })
      Row() {
        this.ToolButton('0°', this.rotation === 0 ? '#FF0A59F7' : '#FF3B5A80', () => {
          this.rotation = 0; this.applyOrientation(0);
        })
        this.ToolButton('90°', this.rotation === 90 ? '#FF0A59F7' : '#FF3B5A80', () => {
          this.rotation = 90; this.applyOrientation(90);
        })
        this.ToolButton('180°', this.rotation === 180 ? '#FF0A59F7' : '#FF3B5A80', () => {
          this.rotation = 180; this.applyOrientation(180);
        })
        this.ToolButton('270°', this.rotation === 270 ? '#FF0A59F7' : '#FF3B5A80', () => {
          this.rotation = 270; this.applyOrientation(270);
        })
      }.width('100%').margin({ top: 6 })
      Row() {
        this.ToolButton('分辨率', '#FF3B5A80', () => {
          this.dockPanel = 0;
          this.activeSheet = SHEET_RESOLUTION;
        })
      }.width('100%').margin({ top: 6 })
    }
    .padding(12).borderRadius(14)
    .backgroundColor($r('app.color.toolbar_background'))
    .constraintSize({ maxWidth: '76%' })
    .margin({ left: 8 })
  }

  @Builder
  ModifierKey(label: string, on: boolean, toggle: () => void) {
    Button(label).fontSize(12).height(34).layoutWeight(1)
      .backgroundColor(on ? '#FF0A59F7' : '#FF3B5A80')
      .fontColor(Color.White)
      .onClick(() => toggle())
  }

  @Builder
  KeyboardSheet() {
    Column() {
      TextInput({ text: this.keyboardText, placeholder: '输入文字后点「发送文字」' })
        .height(44).fontSize(15).width('100%')
        .onChange((v: string): void => { this.keyboardText = v; })
      Row() {
        this.ModifierKey('Shift', this.shiftOn, () => this.shiftOn = !this.shiftOn)
        this.ModifierKey('Ctrl', this.ctrlOn, () => this.ctrlOn = !this.ctrlOn)
        this.ModifierKey('Alt', this.altOn, () => this.altOn = !this.altOn)
        this.ModifierKey('Win', this.winOn, () => this.winOn = !this.winOn)
      }.width('100%').margin({ top: 8 })
      ForEach(KEY_ROWS, (row: KeyDef[]) => {
        Row() {
          ForEach(row, (k: KeyDef) => {
            Button(k.label).fontSize(11).height(32).layoutWeight(k.weight)
              .backgroundColor('#FF3B5A80').fontColor(Color.White)
              .margin({ left: 2, right: 2 })
              .onClick(() => this.sendKey(k.code))
          }, (k: KeyDef) => k.label)
        }.width('100%').margin({ top: 6 })
      }, (row: KeyDef[], idx: number) => String(idx))
      Row() {
        this.ToolButton('发送文字', '#FF0A59F7', () => this.sendText())
        this.ToolButton('Ctrl+C', '#FF3B5A80', () => {
          connectionService.sendKeyboard(KeyAction.COMBO, 67, 67, KeyModifier.CTRL, 0);
        })
        this.ToolButton('Ctrl+V', '#FF3B5A80', () => {
          connectionService.sendKeyboard(KeyAction.COMBO, 86, 86, KeyModifier.CTRL, 0);
        })
      }.width('100%').margin({ top: 10 })
    }.padding(14)
  }

  @Builder
  RotationSheet() {
    Column() {
      Text('选择屏幕方向，并同步通知主机').fontSize(14)
        .fontColor($r('app.color.text_secondary')).width('100%')
      Row() {
        this.ToolButton('竖屏 0°', '#FF3B5A80', () => { this.rotation = 0; this.applyOrientation(0); this.activeSheet = SHEET_NONE; })
        this.ToolButton('横屏 90°', '#FF3B5A80', () => { this.rotation = 90; this.applyOrientation(90); this.activeSheet = SHEET_NONE; })
      }.width('100%').margin({ top: 14 })
      Row() {
        this.ToolButton('180°', '#FF3B5A80', () => { this.rotation = 180; this.applyOrientation(180); this.activeSheet = SHEET_NONE; })
        this.ToolButton('270°', '#FF3B5A80', () => { this.rotation = 270; this.applyOrientation(270); this.activeSheet = SHEET_NONE; })
      }.width('100%').margin({ top: 8 })
    }.padding(18)
  }

  @Builder
  ResolutionSheet() {
    Column() {
      Text('向主机请求的目标分辨率（宽度与高度需为偶数）')
        .fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
      Row() {
        TextInput({ text: this.resW }).type(InputType.Number).layoutWeight(1).height(42)
          .onChange((v: string): void => { this.resW = v; })
        Text('×').fontSize(18).margin({ left: 10, right: 10 })
        TextInput({ text: this.resH }).type(InputType.Number).layoutWeight(1).height(42)
          .onChange((v: string): void => { this.resH = v; })
      }.width('100%').margin({ top: 12 })
      Button('应用').width('100%').height(42).margin({ top: 16 })
        .backgroundColor($r('app.color.primary'))
        .onClick(() => {
          const w: number = Number.parseInt(this.resW, 10);
          const h: number = Number.parseInt(this.resH, 10);
          if (Number.isNaN(w) || Number.isNaN(h) || w % 2 !== 0 || h % 2 !== 0) {
            promptAction.showToast({ message: s($r('app.string.err_multiple_of_2')) });
            return;
          }
          settings.putNumber('harmony_resolution_width', w);
          settings.putNumber('harmony_resolution_height', h);
          connectionService.requestResolution(w, h, settings.getFps(), this.rotation,
            settings.getQuality());
          this.activeSheet = SHEET_NONE;
        })
    }.padding(18)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.frame !== undefined) {
        Image(this.frame as image.PixelMap)
          .width('100%').height('100%')
          .objectFit(this.displayFill ? ImageFit.Fill : ImageFit.Contain)
          .scale({ x: this.zoom, y: this.zoom, centerX: '50%', centerY: '50%' })
          .translate({ x: this.panX, y: this.panY })
          .backgroundColor($r('app.color.display_background'))
      } else {
        Column() {
          Text('🖥').fontSize(64)
          Text($r('app.string.display_placeholder'))
            .fontSize(16).fontColor('#FFB0BAC7').margin({ top: 16 })
          Text('双指缩放 / 拖动平移 · 单指点击或移动')
            .fontSize(12).fontColor('#FF7A8593').margin({ top: 8 })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.display_background'))
      }

      // 触摸层
      Column() {}
        .width('100%').height('100%')
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          this.viewW = Number(newValue.width) > 0 ? Number(newValue.width) : 1;
          this.viewH = Number(newValue.height) > 0 ? Number(newValue.height) : 1;
        })
        .onTouch((event: TouchEvent): void => { this.onPointerEvent(event); })

      // 触摸反馈圆点
      if (this.dotShow) {
        Column()
          .width(26).height(26).borderRadius(13)
          .backgroundColor('#440059F7')
          .border({ width: 2, color: '#880059F7' })
          .position({ x: this.dotX - 13, y: this.dotY - 13 })
          .hitTestBehavior(HitTestMode.None)
      }

      // 顶部状态
      Row() {
        Text(this.name).fontSize(13).fontColor(Color.White).layoutWeight(1).maxLines(1)
        Text(this.status).fontSize(12).fontColor('#FF9FE3B0')
      }
      .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#99000000')
      .hitTestBehavior(HitTestMode.Transparent)

      if (this.statsText.length > 0) {
        Text(this.statsText).fontSize(11).fontColor('#FFD0D6DE')
          .margin({ top: 46, left: 16 })
          .hitTestBehavior(HitTestMode.Transparent)
      }

      // 右侧图标坞 + 内嵌面板（参照真 APK：竖排圆形图标，面板从右侧滑出，不越界）
      Row() {
        if (this.dockPanel === 1) {
          this.OpPanel()
        }
        if (this.dockPanel === 2) {
          this.DisplayPanel()
        }
        Column() {
          this.DockButton('操作', '☰', '#F01B2A41', this.dockPanel === 1, (): void => {
            this.dockPanel = this.dockPanel === 1 ? 0 : 1;
          })
          this.DockButton('键盘', '⌨', '#F01B2A41', this.activeSheet === SHEET_KEYBOARD, (): void => {
            this.dockPanel = 0;
            this.activeSheet = SHEET_KEYBOARD;
          })
          this.DockButton('显示', '🖥', '#F01B2A41', this.dockPanel === 2, (): void => {
            this.dockPanel = this.dockPanel === 2 ? 0 : 2;
          })
          this.DockButton('断开', '✕', '#F0C0392B', false, (): void => {
            this.goBack();
          })
        }
        .margin({ left: 8 })
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%').height('100%')
    .bindSheet(this.activeSheet !== SHEET_NONE, this.ActiveSheet(), {
      height: this.sheetHeight(),
      dragBar: true,
      title: { title: this.sheetTitle() },
      onDisappear: (): void => { this.activeSheet = SHEET_NONE; }
    })
  }

  private sheetTitle(): ResourceStr {
    if (this.activeSheet === SHEET_ROTATION) {
      return '屏幕旋转';
    }
    if (this.activeSheet === SHEET_RESOLUTION) {
      return '远程分辨率';
    }
    return $r('app.string.btn_keyboard');
  }

  private sheetHeight(): number {
    if (this.activeSheet === SHEET_ROTATION) {
      return 220;
    }
    if (this.activeSheet === SHEET_RESOLUTION) {
      return 260;
    }
    return 360;
  }

  @Builder
  ActiveSheet() {
    if (this.activeSheet === SHEET_KEYBOARD) {
      this.KeyboardSheet()
    } else if (this.activeSheet === SHEET_ROTATION) {
      this.RotationSheet()
    } else if (this.activeSheet === SHEET_RESOLUTION) {
      this.ResolutionSheet()
    }
  }
}
