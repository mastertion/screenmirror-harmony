/**
 * 协议扩展层：控制报文、输入事件、帧头解析、音频与原始帧载荷
 *
 * 说明（保持与逆向报告一致的诚实边界）：
 *  - 包头类型枚举、端口、字节序、身份包与发现应答来自 classes.dex 字节码，可信度高；
 *  - 本节中输入事件/控制报文的「载荷内部字段」属于按 Android 端 SAMotionEvent /
 *    SAFlowControl 结构做的等价重建，服务端以 128B 包头中的 type 分派，
 *    字段语义需要抓包最终校准。工程把它集中放在本文件，便于日后按抓包结果替换。
 */
import { buffer } from '@kit.ArkTS';
import {
  HeaderType, ClientType, OsType, Compression,
  HeaderOffset, HEADER_SIZE, IDENT_PAYLOAD_SIZE,
  newHeader, joinPacket, toArrayBuffer, writeUtf16Le
} from './Protocol';

/* ------------------------- 输入事件枚举 ------------------------- */

/** 鼠标动作，对应 Android MotionEvent.getActionMasked() 的常用值 */
export enum MouseAction {
  MOVE = 2,
  DOWN = 0,
  UP = 1,
  SCROLL = 8,
  HOVER = 7,
  CANCEL = 3
}

/** 触摸动作 */
export enum TouchAction {
  DOWN = 0,
  UP = 1,
  MOVE = 2,
  CANCEL = 3
}

/** 键盘动作 */
export enum KeyAction {
  DOWN = 0,
  UP = 1,
  CHAR = 2,
  COMBO = 3
}

/** 鼠标按键位掩码 */
export class MouseButton {
  static readonly NONE: number = 0;
  static readonly LEFT: number = 1;
  static readonly RIGHT: number = 2;
  static readonly MIDDLE: number = 4;
  static readonly BACK: number = 8;
  static readonly FORWARD: number = 16;
}

/** 键盘修饰键位掩码 */
export class KeyModifier {
  static readonly NONE: number = 0;
  static readonly SHIFT: number = 1;
  static readonly CTRL: number = 2;
  static readonly ALT: number = 4;
  static readonly META: number = 8;   // Windows / Super
  static readonly NUMLOCK: number = 16;
  static readonly CAPSLOCK: number = 32;
}

/** 单个触点 */
export interface PointerSample {
  id: number;        // 触点 ID（多点触控区分手指）
  x: number;         // 归一化 0..1
  y: number;         // 归一化 0..1
  pressure: number;  // 0..1，鼠标固定 1
  radius: number;    // 接触面积（归一化）
}

/** 手写笔 */
export interface PenSample {
  x: number;
  y: number;
  pressure: number;
  tiltX: number;
  tiltY: number;
  barrel: boolean;   // 侧开关
  eraser: boolean;
}

/* ------------------------- 控制报文构造 ------------------------- */

/**
 * 帧缓冲流控 ACK（type=7）。
 * 2026-11-13 抓包定案（真 APK 会话 33806）：客户端周期发送的是【全零 128B】type=7，
 * 不携带任何 sequence/字节计数字段，间隔约 190ms。
 */
export function buildFlowControlAck(): ArrayBuffer {
  return toArrayBuffer(newHeader(HeaderType.FRAMEBUFFER_FLOW_CONTROL_ACK, 0));
}

/**
 * 视频通道身份包（2026-11-13 抓包定案，来源真 APK 会话 33806 的 462B 包逐字段核对）：
 *   [8]=4 [12]=8 [16]=0(DISPLAY_MONITOR) [20]=3(ANDROID) [24]=3(MJPEG)
 *   [28]=2 [32]=60(fps) [44]=30 [46]=4 [48]=2 [52]=设备屏高 [56]=请求缓冲高
 *   [88]=设备屏宽 [92]=请求缓冲宽 [124]=1
 * 服务端按请求缓冲 1024x768 缩放桌面并以横带 JPEG 推流。
 * 关键：身份包之后【不能】再发 DISPLAY_SETTINGS/VISIBILITY，
 * 服务端收到多余报文会直接静默断开（抓包实测 0 字节回包）。
 */
export function buildVideoIdentification(instanceId: string, deviceName: string,
                                         deviceW: number, deviceH: number,
                                         bufW: number, bufH: number): ArrayBuffer {
  const h: buffer.Buffer = newHeader(HeaderType.IDENTIFICATION, IDENT_PAYLOAD_SIZE);
  h.writeInt32LE(4, HeaderOffset.F1);                      // [8]
  h.writeInt32LE(8, HeaderOffset.F2);                      // [12]
  h.writeInt32LE(ClientType.DISPLAY_MONITOR, HeaderOffset.CLIENT_TYPE); // [16]=0
  h.writeInt32LE(OsType.ANDROID, HeaderOffset.OS_TYPE);    // [20]=3
  h.writeInt32LE(Compression.MJPEG, HeaderOffset.COMPRESSION); // [24]=3
  h.writeInt32LE(2, HeaderOffset.COLOR_DEPTH);             // [28]=2
  h.writeInt32LE(60, HeaderOffset.FPS);                    // [32]=60
  h.writeInt16LE(30, 44);                                  // [44]
  h.writeInt16LE(4, 46);                                   // [46]
  h.writeInt32LE(2, 48);                                   // [48]
  h.writeInt32LE(deviceH > 0 ? deviceH : 2848, 52);        // [52] 设备屏高
  h.writeInt32LE(bufW > 0 ? bufW : 1024, 56);              // [56] 请求缓冲宽（实测1920x1080可行）
  h.writeInt32LE(deviceW > 0 ? deviceW : 1320, 88);        // [88] 设备屏宽
  h.writeInt32LE(bufH > 0 ? bufH : 768, 92);               // [92] 请求缓冲高
  h.writeInt32LE(1, HeaderOffset.TAIL);                    // [124]
  const p: buffer.Buffer = buffer.alloc(IDENT_PAYLOAD_SIZE);
  writeUtf16Le(p, 0, instanceId, 39);
  writeUtf16Le(p, 78, deviceName, 128);
  return toArrayBuffer(joinPacket(h, p));
}

/** 上报客户端期望的显示设置（type=6） */
export function buildDisplaySettings(width: number, height: number, fps: number,
                                     rotation: number, quality: number): ArrayBuffer {
  const h: buffer.Buffer = newHeader(HeaderType.EVT_DISPLAY_SETTINGS, 24);
  h.writeInt32LE(width, HeaderOffset.F1);
  h.writeInt32LE(height, HeaderOffset.F2);
  const p: buffer.Buffer = buffer.alloc(24);
  p.writeInt32LE(Math.max(320, Math.round(width)), 0);
  p.writeInt32LE(Math.max(240, Math.round(height)), 4);
  p.writeInt32LE(Math.max(1, Math.round(fps)), 8);
  p.writeInt32LE(Math.round(rotation), 12);
  p.writeInt32LE(Math.round(quality), 16);
  p.writeInt32LE(0, 20);
  return toArrayBuffer(joinPacket(h, p));
}

/** 屏幕旋转上报（type=9），0/90/180/270 */
export function buildRotation(degrees: number): ArrayBuffer {
  const h: buffer.Buffer = newHeader(HeaderType.ROTATION, 8);
  const p: buffer.Buffer = buffer.alloc(8);
  p.writeInt32LE(((Math.round(degrees) % 360) + 360) % 360, 0);
  p.writeInt32LE(0, 4);
  return toArrayBuffer(joinPacket(h, p));
}

/** 画面可见性（type=3）：切后台时通知服务端暂停推流，省电省带宽 */
export function buildVisibility(visible: boolean): ArrayBuffer {
  const h: buffer.Buffer = newHeader(HeaderType.VISIBILITY, 8);
  const p: buffer.Buffer = buffer.alloc(8);
  p.writeInt32LE(visible ? 1 : 0, 0);
  p.writeInt32LE(0, 4);
  return toArrayBuffer(joinPacket(h, p));
}

/**
 * 连接密码（原 Android 端在 TLS-PSK 分支之前有一段明文认证）。
 * 载荷布局按 UTF-16LE + 长度前缀重建，需抓包复核。
 */
export function buildPasswordAuth(password: string): ArrayBuffer {
  const chars: number = Math.min(password.length, 128);
  const p: buffer.Buffer = buffer.alloc(8 + chars * 2);
  p.writeInt32LE(chars * 2, 0);
  p.writeInt32LE(1, 4); // 版本标记
  writeUtf16Le(p, 8, password, chars);
  const h: buffer.Buffer = newHeader(HeaderType.IDENTIFICATION, p.length);
  h.writeInt32LE(4, HeaderOffset.F1);
  h.writeInt32LE(9, HeaderOffset.F2); // 9 = 密码认证子类型
  return toArrayBuffer(joinPacket(h, p));
}

/** 音频通道身份包：clientType=AUDIO，其余与画面通道一致 */
export function buildAudioIdentification(instanceId: string, deviceName: string): ArrayBuffer {
  const h: buffer.Buffer = newHeader(HeaderType.IDENTIFICATION, IDENT_PAYLOAD_SIZE);
  h.writeInt32LE(4, HeaderOffset.F1);
  h.writeInt32LE(8, HeaderOffset.F2);
  h.writeInt32LE(ClientType.AUDIO, HeaderOffset.CLIENT_TYPE);
  h.writeInt32LE(OsType.ANDROID, HeaderOffset.OS_TYPE);
  h.writeInt32LE(Compression.OFF, HeaderOffset.COMPRESSION);
  const p: buffer.Buffer = buffer.alloc(IDENT_PAYLOAD_SIZE);
  writeUtf16Le(p, 0, instanceId, 39);
  writeUtf16Le(p, 78, deviceName, 128);
  return toArrayBuffer(joinPacket(h, p));
}

/* ------------------------- 输入事件构造 ------------------------- */

/**
 * 通用输入包：128B 头 + 载荷。
 * 载荷采用「动作 + 修饰/按键 + 浮点坐标 + 时间戳 + 设备 ID」的固定 32B 记录，
 * 多点触控在后面追加 N 个 24B 触点记录。
 */
function inputHeader(type: HeaderType, action: number, buttons: number,
                     pointerCount: number, extra: number): buffer.Buffer {
  const payloadLength: number = 32 + pointerCount * 24;
  const h: buffer.Buffer = newHeader(type, payloadLength);
  h.writeInt32LE(action, HeaderOffset.F1);
  h.writeInt32LE(buttons, HeaderOffset.F2);
  h.writeInt16LE(pointerCount, HeaderOffset.SHORT_1);
  h.writeInt16LE(extra, HeaderOffset.SHORT_2);
  return h;
}

function inputRecord(action: number, buttons: number, x: number, y: number,
                     pressure: number, pointerId: number, timestamp: number,
                     deviceId: number): buffer.Buffer {
  const p: buffer.Buffer = buffer.alloc(32);
  p.writeInt32LE(action, 0);
  p.writeInt32LE(buttons, 4);
  p.writeFloatLE(Math.max(0, Math.min(1, x)), 8);
  p.writeFloatLE(Math.max(0, Math.min(1, y)), 12);
  p.writeFloatLE(Math.max(0, Math.min(1, pressure)), 16);
  p.writeInt32LE(pointerId, 20);
  p.writeInt32LE(timestamp & 0x7FFFFFFF, 24);
  p.writeInt32LE(deviceId, 28);
  return p;
}

function pointerRecord(pt: PointerSample): buffer.Buffer {
  const p: buffer.Buffer = buffer.alloc(24);
  p.writeInt32LE(pt.id, 0);
  p.writeFloatLE(Math.max(0, Math.min(1, pt.x)), 4);
  p.writeFloatLE(Math.max(0, Math.min(1, pt.y)), 8);
  p.writeFloatLE(Math.max(0, Math.min(1, pt.pressure)), 12);
  p.writeFloatLE(Math.max(0, Math.min(1, pt.radius)), 16);
  p.writeInt32LE(0, 20);
  return p;
}

/** 鼠标：移动 / 按下 / 抬起 / 滚轮 */
export function buildMouseEvent(action: MouseAction, x: number, y: number,
                                buttons: number, wheelDelta: number,
                                timestamp: number): ArrayBuffer {
  const h: buffer.Buffer = inputHeader(HeaderType.EVT_INPUT_MOUSE, action, buttons, 1,
    Math.round(wheelDelta));
  const payload: buffer.Buffer = buffer.concat([
    inputRecord(action, buttons, x, y, 1, 0, timestamp, 0),
    pointerRecord({ id: 0, x: x, y: y, pressure: 1, radius: 0 })
  ]) as buffer.Buffer;
  return toArrayBuffer(joinPacket(h, payload));
}

/**
 * 触摸输入（type=12）—— 2026-11-13 抓包定案：
 * 128B 头、0 载荷，全部信息在头字段：
 *   [8]=Y [12]=X（设备像素坐标） [16]=屏高 [20]=屏宽
 *   [24]=动作（3=按下 1=移动 5=抬起） [28]=时间戳（ms，单调递增）
 * 入参 x/y 为归一化 0..1 坐标，按屏宽高换算成设备像素。
 * 多点触控真机未采集到样本，当前按逐点单包处理。
 */
export function buildTouchEvent(action: TouchAction, points: PointerSample[],
                                timestamp: number, screenW: number,
                                screenH: number): ArrayBuffer {
  const first: PointerSample = points.length > 0 ? points[0]
    : { id: 0, x: 0, y: 0, pressure: 1, radius: 0 };
  const w: number = screenW > 0 ? screenW : 1320;
  const hgt: number = screenH > 0 ? screenH : 2848;
  const x: number = Math.round(Math.max(0, Math.min(1, first.x)) * w);
  const y: number = Math.round(Math.max(0, Math.min(1, first.y)) * hgt);
  const h: buffer.Buffer = newHeader(HeaderType.EVT_INPUT_TOUCH, 0);
  h.writeInt32LE(y, 8);
  h.writeInt32LE(x, 12);
  h.writeInt32LE(hgt, 16);
  h.writeInt32LE(w, 20);
  const code: number = action === TouchAction.DOWN ? 3
    : action === TouchAction.UP ? 5 : 1;
  h.writeInt32LE(code, 24);
  h.writeInt32LE(timestamp % 2147483647, 28);
  return toArrayBuffer(h);
}

/** 键盘：虚拟键码 + Unicode + 修饰键 */
export function buildKeyboardEvent(action: KeyAction, keyCode: number, unicode: number,
                                   modifiers: number, repeat: number,
                                   timestamp: number): ArrayBuffer {
  const h: buffer.Buffer = inputHeader(HeaderType.EVT_INPUT_KEYBOARD, action, modifiers, 0, repeat);
  const p: buffer.Buffer = inputRecord(action, modifiers, 0, 0, 0, keyCode, timestamp, 2);
  // 复用坐标槽存放 Unicode 码点与扫描码
  p.writeInt32LE(unicode, 8);
  p.writeInt32LE(keyCode, 12);
  p.writeInt32LE(repeat, 16);
  return toArrayBuffer(joinPacket(h, p));
}

/** 手写笔 / 触控笔（含压感、倾角、侧开关、橡皮擦） */
export function buildPenEvent(action: TouchAction, pen: PenSample,
                              timestamp: number): ArrayBuffer {
  const h: buffer.Buffer = inputHeader(HeaderType.EVT_INPUT_PEN, action,
    (pen.barrel ? 1 : 0) | (pen.eraser ? 2 : 0), 1, Math.round(pen.pressure * 1000));
  const p: buffer.Buffer = buffer.concat([
    inputRecord(action, 0, pen.x, pen.y, pen.pressure, 0, timestamp, 3),
    pointerRecord({ id: 0, x: pen.x, y: pen.y, pressure: pen.pressure, radius: 0 })
  ]) as buffer.Buffer;
  // 倾角放在尾部 8 字节
  const tilt: buffer.Buffer = buffer.alloc(8);
  tilt.writeFloatLE(pen.tiltX, 0);
  tilt.writeFloatLE(pen.tiltY, 4);
  return toArrayBuffer(joinPacket(h, buffer.concat([p, tilt]) as buffer.Buffer));
}

/* ------------------------- 帧头与载荷解析 ------------------------- */

/**
 * 帧缓冲包头里的画面元信息 —— 2026-11-13 抓包定案（真 APK 会话 33806 全部 68 帧）：
 *   [8]  = 显示缓冲宽（如 1024）
 *   [12] = 显示缓冲高（如 768）
 *   [16] = stride（4096，原始格式用）
 *   [20] = 质量/编码标记（21）
 *   [24] = 更新区 X（实测恒 0）
 *   [28] = 更新区 Y（横带起点）
 *   [32] = 更新区宽（= JPEG 宽）
 *   [36] = 更新区 Y 底（= Y + JPEG 高）
 *   [48] = fps（60）
 * 服务端把整屏按最多 192px 高的横带推送，且每个逻辑更新会连发 4 份
 * （内容 MD5 相同、[36] 逐份变化），客户端按内容去重后逐带贴回缓冲即可。
 */
export interface FrameMeta {
  width: number;
  height: number;
  x: number;
  y: number;
  stride: number;
  sequence: number;
  flags: number;
  displayWidth: number;
  displayHeight: number;
  fps: number;
  quality: number;
}

export function parseFrameMeta(header: buffer.Buffer): FrameMeta {
  const read = (off: number, def: number): number => {
    if (off + 4 > header.length) {
      return def;
    }
    const v: number = header.readInt32LE(off);
    return v >= 0 && v < 65536 ? v : def;
  };
  const y: number = read(28, 0);
  const yBottom: number = read(36, y);
  return {
    displayWidth: read(8, 0),
    displayHeight: read(12, 0),
    x: read(24, 0),
    y: y,
    width: read(32, 0),
    height: Math.max(0, yBottom - y),
    stride: read(16, 0),
    fps: read(48, 0),
    quality: read(20, 0),
    sequence: header.length >= 92 ? header.readInt32LE(88) : 0,
    flags: header.length >= 128 ? header.readInt32LE(124) : 0
  };
}

/**
 * 原始帧（Compression.OFF / YUV_PLAIN）转换。
 * Windows 端推送的是 BGRA_8888 位图，鸿蒙 PixelMap 直接支持 BGRA_8888，
 * 因此只需按宽高补齐/截断即可；YUV 变体按灰度兜底（需抓包确认 FourCC）。
 */
export function normalizeRawFrame(payload: buffer.Buffer, meta: FrameMeta): buffer.Buffer {
  const pixels: number = meta.width * meta.height * 4;
  if (meta.width > 0 && meta.height > 0 && payload.length >= pixels) {
    return payload.subarray(0, pixels) as buffer.Buffer;
  }
  return payload;
}

/** 判断 H.264 Annex-B 起始码 */
export function isH264AnnexB(payload: buffer.Buffer): boolean {
  if (payload.length < 4) {
    return false;
  }
  const a: number = payload.readUInt8(0);
  const b: number = payload.readUInt8(1);
  const c: number = payload.readUInt8(2);
  const d: number = payload.readUInt8(3);
  return (a === 0 && b === 0 && c === 0 && d === 1) ||
    (a === 0 && b === 0 && c === 1);
}

/** 判断 JPEG SOI */
export function isJpeg(payload: buffer.Buffer): boolean {
  return payload.length >= 2 && payload.readUInt8(0) === 0xFF && payload.readUInt8(1) === 0xD8;
}

/**
 * 音频块 —— 2026-11-13 抓包定案：参数在 128B 包头里，载荷是纯 PCM：
 *   [8]=声道数(2) [12]=采样率(48000) [16]=位深(16) [20]=块字节数(1920)
 */
export interface AudioChunk {
  sampleRate: number;
  channels: number;
  bits: number;
  frames: number;
  pcm: ArrayBuffer;
}

export function parseAudioChunk(header: buffer.Buffer, payload: buffer.Buffer): AudioChunk | undefined {
  if (payload.length <= 0) {
    return undefined;
  }
  const read = (off: number, def: number): number => {
    if (off + 4 > header.length) {
      return def;
    }
    const v: number = header.readInt32LE(off);
    return v > 0 && v < 1048576 ? v : def;
  };
  const sampleRate: number = read(12, 48000);
  const channels: number = read(8, 2);
  const bits: number = read(16, 16);
  return {
    sampleRate: sampleRate,
    channels: channels > 0 && channels <= 8 ? channels : 2,
    bits: bits,
    frames: Math.floor(payload.length * 8 / bits / (channels > 0 ? channels : 2)),
    pcm: toArrayBuffer(payload)
  };
}

/* ------------------------- 常量与工具 ------------------------- */

/** 常用 Windows 虚拟键码（用于软键盘回传） */
export class VKey {
  static readonly BACKSPACE: number = 8;
  static readonly TAB: number = 9;
  static readonly ENTER: number = 13;
  static readonly SHIFT: number = 16;
  static readonly CTRL: number = 17;
  static readonly ALT: number = 18;
  static readonly CAPSLOCK: number = 20;
  static readonly ESC: number = 27;
  static readonly SPACE: number = 32;
  static readonly PAGEUP: number = 33;
  static readonly PAGEDOWN: number = 34;
  static readonly END: number = 35;
  static readonly HOME: number = 36;
  static readonly LEFT: number = 37;
  static readonly UP: number = 38;
  static readonly RIGHT: number = 39;
  static readonly DOWN: number = 40;
  static readonly INSERT: number = 45;
  static readonly DELETE: number = 46;
  static readonly LWIN: number = 91;
  static readonly F1: number = 112;
  static readonly F12: number = 123;
}

export function nowMs(): number {
  return Date.now() & 0x7FFFFFFF;
}
