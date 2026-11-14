/**
 * spacedesk 协议实现（由 spacedesk_59441.apk 逆向还原）
 * ------------------------------------------------------------------
 * 所有多字节整数均为小端（Little Endian）。
 * 所有报文（除 UDP 发现应答）都由两部分组成：
 *
 *   [ 128 字节包头 ][ payloadLength 字节负载 ]
 *
 * 包头第 0 个 int32 为报文类型（SdHeaderType），
 * 第 4 个 int32 为紧随其后的负载字节数。
 * ------------------------------------------------------------------
 */

/** 包头固定长度 */
export const SD_HEADER_SIZE: number = 128;
/** UDP 发现广播端口 */
export const SD_DISCOVERY_PORT: number = 28252;
/** UDP 发现广播内容（含结尾 0x00） */
export const SD_DISCOVERY_MAGIC: string = 'SPACEDESK-NET-CLIENT\u0000';
/** 发现应答固定长度：256 字节名称 + 4 IP + 4 端口 + 4 OS + 其他标志 */
export const SD_DISCOVERY_REPLY_SIZE: number = 308;
/** 客户端标识（Identification）负载固定长度 */
export const SD_IDENT_PAYLOAD_SIZE: number = 334;
/** 单包负载上限，防异常数据导致内存暴涨 */
export const SD_MAX_PAYLOAD: number = 16 * 1024 * 1024;
/** 服务器操作系统枚举值中的 macOS（需要额外的 H264 码流规整） */
export const SD_SERVER_OS_MACOS: number = 11;

/** 包头类型（对应 APK 内 PROTOCOL_SPCDSK_SMPL_HEADER_TYPE_* 枚举顺序） */
export enum SdHeaderType {
  Identification = 0,
  Ping = 1,
  Framebuffer = 2,
  Visibility = 3,
  DisplaySettings = 4,
  Unused = 5,
  EvtDisplaySettings = 6,
  FramebufferAck = 7,
  Disconnect = 8,
  Rotation = 9,
  EvtMouse = 10,
  EvtKeyboard = 11,
  EvtTouch = 12,
  EvtPen = 13,
  Audio = 14
}

/** 压缩方式 */
export enum SdCompression {
  Off = 0,
  YuvPlain = 1,
  Unused = 2,
  Mjpeg = 3,
  H264 = 4,
  ChooseBest = 5
}

/** H264/JPEG 采样格式 */
export enum SdColorFormat {
  Yuv444 = 0,
  Yuv422 = 1,
  Yuv420 = 2,
  Gray = 3,
  Yuv440 = 4,
  Yuv411 = 5
}

/** 客户端类型 */
export enum SdClientType {
  DisplayMonitor = 0,
  DisplayMonitorWebBrowser = 1,
  Reserved = 2,
  Audio = 3
}

/** 客户端操作系统类型（服务器据此选择编码策略，安卓端固定上报 Android） */
export enum SdOsType {
  Unknown = 0,
  WindowsNative = 1,
  WindowsUwp = 2,
  Android = 3,
  Ios = 4
}

/** 授权类型 */
export enum SdLicenseType {
  None = 0,
  NonCommercialBasic = 1,
  NonCommercialAdvanced = 2,
  BusinessAndroid = 3,
  BusinessWindowsUwp = 4,
  BusinessIos = 5
}

/** 服务器操作系统类型（发现应答 offset 264） */
export enum SdServerOs {
  Unknown = 0,
  WindowsServer2008R2 = 1,
  Windows7 = 2,
  WindowsServer2012 = 3,
  Windows8 = 4,
  WindowsServer2012R2 = 5,
  Windows8_1 = 6,
  WindowsServer2016 = 7,
  Windows10 = 8,
  WindowsServer2022 = 9,
  Windows11 = 10,
  MacOS = 11
}

/** 流状态 */
export enum SdStreamState {
  Undefined = 0,
  Pause = 1,
  Play = 2
}

/** 客户端断连原因（发给服务器） */
export enum SdDisconnectReason {
  GracefulRegular = 0,
  H264InitFailed = 1,
  H264Failed = 2
}

/** Ping 选项 */
export enum SdPingOption {
  Legacy = 0,
  EchoRequest = 1,
  EchoReply = 2
}

/** 触摸动作（绝对模式下的原始取值，直接照搬 APK 中的映射） */
export enum SdTouchAction {
  Move = 1,
  Down = 3,
  Up = 5
}

/** 键盘动作 */
/**
 * 键盘动作取值（与 APK 一致）：
 *   onKeyDown 里写 0，onKeyUp 里写 2，软键盘字符写 4。
 *   注意不是 1/0 —— 旧版本这里写反了。
 */
export enum SdKeyAction {
  Down = 0,
  Up = 2,
  /** 以 Unicode 字符方式输入，字符码放在包头 offset 12 */
  Text = 4
}

/**
 * 收到的报文（包头 + 负载）。
 * 各字段偏移见下面各 getter 的注释。
 */
export class SdPacket {
  readonly header: Uint8Array;
  readonly payload: Uint8Array;
  private readonly view: DataView;

  constructor(header: Uint8Array, payload: Uint8Array) {
    this.header = header;
    this.payload = payload;
    this.view = new DataView(header.buffer, header.byteOffset, header.byteLength);
  }

  private i32(offset: number): number {
    return this.view.getInt32(offset, true);
  }

  /** offset 0：报文类型 */
  get headerType(): number {
    return this.i32(0);
  }

  /** offset 4：负载长度 */
  get payloadLength(): number {
    return this.i32(4);
  }

  // ---- 帧缓冲（Framebuffer）字段 ----
  /** offset 8：画面宽度（像素） */
  get width(): number {
    return this.i32(8);
  }

  /** offset 12：画面高度（像素） */
  get height(): number {
    return this.i32(12);
  }

  /** offset 16：行跨距（字节） */
  get pitch(): number {
    return this.i32(16);
  }

  /** offset 24：本次更新矩形 left */
  get rectLeft(): number {
    return this.i32(24);
  }

  /** offset 28：本次更新矩形 top */
  get rectTop(): number {
    return this.i32(28);
  }

  /** offset 32：本次更新矩形 right */
  get rectRight(): number {
    return this.i32(32);
  }

  /** offset 36：本次更新矩形 bottom */
  get rectBottom(): number {
    return this.i32(36);
  }

  /** offset 40：压缩类型 */
  get compression(): number {
    return this.i32(40);
  }

  /** offset 44：采样格式 */
  get colorFormat(): number {
    return this.i32(44);
  }

  /** offset 48：压缩参数（MJPEG 为质量 1~100） */
  get quality(): number {
    return this.i32(48);
  }

  /** offset 64：分片标记，0 表示一帧结束（完整帧），非 0 表示同帧的分片 */
  get fragment(): number {
    return this.i32(64);
  }

  // ---- 其他类型字段 ----
  /** Visibility：offset 8，0=隐藏 1=显示 */
  get visibility(): number {
    return this.i32(8);
  }

  /** Ping：offset 12，SdPingOption */
  get pingOption(): number {
    return this.i32(12);
  }

  /** Disconnect：offset 8，服务器给出的断连原因 */
  get disconnectReason(): number {
    return this.i32(8);
  }

  /** EvtDisplaySettings：offset 8，SdStreamState */
  get streamState(): number {
    return this.i32(8);
  }
}

/** 包头/报文的写入工具 */
export class SdPacketWriter {
  private readonly bytes: Uint8Array;
  private readonly view: DataView;

  constructor(size: number) {
    this.bytes = new Uint8Array(size);
    this.view = new DataView(this.bytes.buffer);
  }

  u8(offset: number, value: number): SdPacketWriter {
    this.bytes[offset] = value & 0xFF;
    return this;
  }

  i16(offset: number, value: number): SdPacketWriter {
    this.view.setInt16(offset, value, true);
    return this;
  }

  i32(offset: number, value: number): SdPacketWriter {
    this.view.setInt32(offset, value, true);
    return this;
  }

  f32(offset: number, value: number): SdPacketWriter {
    this.view.setFloat32(offset, value, true);
    return this;
  }

  toBytes(): Uint8Array {
    return this.bytes;
  }

  toBuffer(): ArrayBuffer {
    return this.bytes.buffer;
  }
}

function newPacket(type: SdHeaderType, payloadSize: number): SdPacketWriter {
  const writer = new SdPacketWriter(SD_HEADER_SIZE + payloadSize);
  writer.i32(0, type);
  writer.i32(4, payloadSize);
  return writer;
}

/** 把收到的原始字节切成包头 + 负载 */
export function parsePacket(bytes: Uint8Array): SdPacket {
  // 这里必须整段复制：收包缓冲区随后会被复用，而帧数据是异步解码的。
  const header = bytes.slice(0, SD_HEADER_SIZE);
  const payload = bytes.length > SD_HEADER_SIZE ? bytes.slice(SD_HEADER_SIZE) : new Uint8Array(0);
  return new SdPacket(header, payload);
}

/** 客户端标识参数 */
export class SdIdentConfig {
  /** 客户端实例 ID（含大括号的 UUID），服务器用于识别重复客户端 */
  clientId: string = '';
  /** 设备名（写入报文的 deviceName 区） */
  deviceName: string = 'HarmonyOS';
  /** 请求帧率 */
  fps: number = 30;
  /** 请求的虚拟显示器宽度（像素） */
  width: number = 1280;
  /** 请求的虚拟显示器高度（像素） */
  height: number = 720;
  /** 压缩质量（写入包头 offset 44，1~100） */
  quality: number = 75;
  /** 协商使用的压缩方式 */
  compression: SdCompression = SdCompression.Mjpeg;
  /** 首选压缩方式 */
  preferredCompression: SdCompression = SdCompression.Mjpeg;
  /** 采样格式 */
  colorFormat: SdColorFormat = SdColorFormat.Yuv420;
  /** 方向提示：4 = 横屏（默认），6 = 竖屏（与 APK 一致） */
  rotation: number = 4;
  /** 授权类型；非商业基础版为 1 */
  licenseType: SdLicenseType = SdLicenseType.NonCommercialBasic;
}

/**
 * 构造客户端标识报文（共 128 + 334 字节）。
 *
 * 包头偏移：
 *   0  类型 = 0
 *   4  负载长度 = 334
 *   8  = 4
 *   12 = 8
 *   16 客户端类型（0 = 显示器）
 *   20 客户端 OS 类型（3 = Android；服务器按此选择编码策略）
 *   24 首选压缩方式
 *   28 采样格式
 *   32 帧率
 *   36 (short) 实际使用的压缩方式
 *   38 (short) = 1
 *   44 (short) 压缩质量（1~100，实测不是帧率）
 *   46 (short) 方向提示
 *   48 显示器数量 = 1
 *   52 int[9] 各显示器宽度
 *   88 int[9] 各显示器高度
 *   124 授权类型
 *
 * 负载（334 字节）：UTF-16LE 文本，偶数偏移写字符低字节。
 *   0..77   实例 ID（最多 39 个字符）
 *   78..333 设备名（最多 128 个字符）
 */
function writeIdentTexts(writer: SdPacketWriter, clientId: string, deviceName: string): void {
  const base = SD_HEADER_SIZE;
  let idChars = 0;
  for (let i = 0; i < clientId.length && idChars < 39; i++) {
    writer.u8(base + idChars * 2, clientId.charCodeAt(i) & 0xFF);
    idChars++;
  }
  let nameChars = 0;
  for (let i = 0; i < deviceName.length && nameChars < 128; i++) {
    writer.u8(base + 78 + nameChars * 2, deviceName.charCodeAt(i) & 0xFF);
    nameChars++;
  }
}

export function buildIdentification(cfg: SdIdentConfig): ArrayBuffer {
  const writer = newPacket(SdHeaderType.Identification, SD_IDENT_PAYLOAD_SIZE);
  writer.i32(8, 4);
  writer.i32(12, 8);
  writer.i32(16, SdClientType.DisplayMonitor);
  writer.i32(20, SdOsType.Android);
  writer.i32(24, cfg.preferredCompression);
  writer.i32(28, cfg.colorFormat);
  writer.i32(32, cfg.fps);
  writer.i16(36, cfg.compression);
  writer.i16(38, 1);
  writer.i16(44, cfg.quality);
  writer.i16(46, cfg.rotation);
  writer.i32(48, 1);
  writer.i32(52, cfg.width);
  writer.i32(88, cfg.height);
  writer.i32(124, cfg.licenseType);
  writeIdentTexts(writer, cfg.clientId, cfg.deviceName);
  return writer.toBuffer();
}

/**
 * 音频客户端标识（抓包校准 cap2.pcapng:33800，2026-11-13）：
 *   off16 = 3（ClientType.Audio），off20 = 3（Android），其余显示参数全 0，授权 = 0。
 * 发出后服务器即在该连接上推送 Audio(14) 报文。
 */
export function buildAudioIdentification(clientId: string, deviceName: string): ArrayBuffer {
  const writer = newPacket(SdHeaderType.Identification, SD_IDENT_PAYLOAD_SIZE);
  writer.i32(8, 4);
  writer.i32(12, 8);
  writer.i32(16, SdClientType.Audio);
  writer.i32(20, SdOsType.Android);
  writer.i32(124, SdLicenseType.None);
  writeIdentTexts(writer, clientId, deviceName);
  return writer.toBuffer();
}

/** 帧缓冲流控应答（每处理完一帧回复一次） */
export function buildFramebufferAck(): ArrayBuffer {
  return newPacket(SdHeaderType.FramebufferAck, 0).toBuffer();
}

/** Ping 应答（type=Ping，offset 12 = EchoReply） */
export function buildPingReply(): ArrayBuffer {
  const writer = newPacket(SdHeaderType.Ping, 0);
  writer.i32(12, SdPingOption.EchoReply);
  return writer.toBuffer();
}

/** 主动 Ping 请求 */
export function buildPingRequest(): ArrayBuffer {
  const writer = newPacket(SdHeaderType.Ping, 0);
  writer.i32(12, SdPingOption.EchoRequest);
  return writer.toBuffer();
}

/** 断连通知（offset 8 = 原因） */
export function buildDisconnect(reason: SdDisconnectReason): ArrayBuffer {
  const writer = newPacket(SdHeaderType.Disconnect, 0);
  writer.i32(8, reason);
  return writer.toBuffer();
}

/** 屏幕旋转通知（offset 8 = 方向值） */
export function buildRotation(rotation: number): ArrayBuffer {
  const writer = newPacket(SdHeaderType.Rotation, 0);
  writer.i32(8, rotation);
  return writer.toBuffer();
}

/** 流控状态（播放/暂停） */
export function buildEventDisplaySettings(state: SdStreamState): ArrayBuffer {
  const writer = newPacket(SdHeaderType.EvtDisplaySettings, 0);
  writer.i32(8, state);
  return writer.toBuffer();
}

/** 触摸报文中的一个触点 */
export class SdTouchPoint {
  x: number = 0;
  y: number = 0;
  id: number = 0;
  action: SdTouchAction = SdTouchAction.Move;

  constructor(x: number, y: number, id: number, action: SdTouchAction) {
    this.x = x;
    this.y = y;
    this.id = id;
    this.action = action;
  }
}

/**
 * 触摸事件报文（type = 12）。
 * 包头偏移：
 *   8  当前触点 x
 *   12 当前触点 y
 *   16 虚拟显示器宽度
 *   20 虚拟显示器高度
 *   24 (short) 动作
 *   26 (short) 主触点 ID
 *   28 时间戳（毫秒，int32）
 *   32 触点个数
 *   36 + i * 12：x(int)、y(int)、动作(short)、触点 ID(short)
 */
export function buildTouch(x: number, y: number, displayWidth: number, displayHeight: number,
                          action: SdTouchAction, pointerId: number,
                          points: SdTouchPoint[], timestampMs: number): ArrayBuffer {
  const writer = newPacket(SdHeaderType.EvtTouch, 0);
  writer.i32(8, Math.round(x));
  writer.i32(12, Math.round(y));
  writer.i32(16, Math.round(displayWidth));
  writer.i32(20, Math.round(displayHeight));
  writer.i16(24, action);
  writer.i16(26, pointerId);
  writer.i32(28, timestampMs);
  writer.i32(32, points.length);
  for (let i = 0; i < points.length && i < 7; i++) {
    const offset = 36 + i * 12;
    writer.i32(offset, Math.round(points[i].x));
    writer.i32(offset + 4, Math.round(points[i].y));
    writer.i16(offset + 8, points[i].action);
    writer.i16(offset + 10, points[i].id);
  }
  return writer.toBuffer();
}

/**
 * 键盘报文（type = 11）。
 *   8  键码
 *   12 字符码（action = Text 时使用）
 *   16 动作（0 抬起 / 1 按下 / 4 文本输入）
 *   20 保留
 */
export function buildKeyboard(keyCode: number, action: SdKeyAction, charCode: number): ArrayBuffer {
  const writer = newPacket(SdHeaderType.EvtKeyboard, 0);
  writer.i32(8, keyCode);
  writer.i32(12, charCode);
  writer.i32(16, action);
  writer.i32(20, 0);
  return writer.toBuffer();
}

/**
 * 鼠标报文（type = 10）。
 * 包头偏移（逆向报告 8.3 节）：
 *   8  x 坐标（虚拟显示器像素）
 *   12 y 坐标
 *   16 滚轮增量（120 = 向上一格，-120 = 向下一格）
 *   20 按键标志：8 = 左键按下，16 = 左键抬起，0 = 仅移动
 *
 * 2026-11-14 字节码级确认（安卓 APK V1.c(Z) 方法反汇编）：
 *   - 参考客户端只发 flags 8/16，且点击时 x@8/y@12/wheel@16 全部写 0（不带坐标）；
 *   - 本实现发送真实坐标与滚轮是超集行为（服务器实测接受）；
 *   - 右键 32/64 在参考客户端中不存在，为纯推测值：无效仅无反应，请真机验证。
 */
export enum SdMouseButton {
  None = 0,
  LeftDown = 8,
  LeftUp = 16,
  RightDown = 32,
  RightUp = 64
}

export function buildMouse(x: number, y: number, flags: number, wheel: number): ArrayBuffer {
  const writer = newPacket(SdHeaderType.EvtMouse, 0);
  writer.i32(8, Math.round(x));
  writer.i32(12, Math.round(y));
  writer.i32(16, Math.round(wheel));
  writer.i32(20, flags);
  writer.i32(24, 0);
  return writer.toBuffer();
}

/** 服务器操作系统显示名 */
export function serverOsName(os: number): string {
  switch (os) {
    case SdServerOs.WindowsServer2008R2: return 'Windows Server 2008 R2';
    case SdServerOs.Windows7: return 'Windows 7';
    case SdServerOs.WindowsServer2012: return 'Windows Server 2012';
    case SdServerOs.Windows8: return 'Windows 8';
    case SdServerOs.WindowsServer2012R2: return 'Windows Server 2012 R2';
    case SdServerOs.Windows8_1: return 'Windows 8.1';
    case SdServerOs.WindowsServer2016: return 'Windows Server 2016';
    case SdServerOs.Windows10: return 'Windows 10';
    case SdServerOs.WindowsServer2022: return 'Windows Server 2022';
    case SdServerOs.Windows11: return 'Windows 11';
    case SdServerOs.MacOS: return 'macOS';
    default: return '';
  }
}
