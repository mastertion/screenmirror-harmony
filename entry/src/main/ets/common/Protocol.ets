/**
 * 局域网扩展屏协议层（HarmonyOS NEXT / ArkTS）
 *
 * 全部常量与报文布局来自对主流 Windows 投屏服务端协议的逆向分析，关键证据：
 *   - w2.f():  UDP 广播目标端口 28252，载荷 "SPACEDESK-NET-CLIENT\0"（UTF-8），连发 5 次
 *   - l2.c():  TCP 连接端口 28252，TCP_NODELAY、trafficClass 224；另有 TLS-PSK 加密分支
 *   - P2.*():  所有多字节字段均为 LITTLE_ENDIAN，字符串为 UTF-16LE
 *   - e.*:     固定 128 字节包头，字段偏移由静态常量给出
 *   - d.a():   334 字节身份数据（实例 ID + 设备名）
 *   - f.*:     308 字节发现应答（256B 名称 + IPv4 + 端口 + 系统类型 + 标志位）
 *
 * 注意：输入事件（鼠标/键盘/触摸）与 H.264 帧载荷的内部字段尚未完全确认，
 *      相关方法以 buildXxxEvent() 形式提供骨架，并明确标注待抓包验证。
 */
import { buffer } from '@kit.ArkTS';

/** TCP 会话端口 / UDP 发现端口（同一个端口） */
export const NET_PORT: number = 28252;
/** 发现探测载荷，注意结尾的 NUL */
export const DISCOVERY_MAGIC: string = 'SPACEDESK-NET-CLIENT\u0000';
export const DISCOVERY_RETRY: number = 5;
export const BROADCAST_ADDRESS: string = '255.255.255.255';

export const HEADER_SIZE: number = 128;
export const IDENT_PAYLOAD_SIZE: number = 334;
export const DISCOVERY_REPLY_SIZE: number = 308;

/* ---------------- 枚举：与 b$* 的 ordinal 一一对应 ---------------- */

/** b$k —— 报文头类型 */
export enum HeaderType {
  IDENTIFICATION = 0,
  PING = 1,
  FRAMEBUFFER = 2,
  VISIBILITY = 3,
  DISPLAY_SETTINGS = 4,
  UNUSED_01 = 5,
  EVT_DISPLAY_SETTINGS = 6,
  FRAMEBUFFER_FLOW_CONTROL_ACK = 7,
  DISCONNECT = 8,
  ROTATION = 9,
  EVT_INPUT_MOUSE = 10,
  EVT_INPUT_KEYBOARD = 11,
  EVT_INPUT_TOUCH = 12,
  EVT_INPUT_PEN = 13,
  AUDIO = 14,
  MAX = 15
}

/** b$h —— 压缩/编码方式 */
export enum Compression {
  OFF = 0,
  YUV_PLAIN = 1,
  UNUSED_01 = 2,
  MJPEG = 3,
  H264 = 4,
  CHOOSE_BEST = 5
}

/** b$g —— 客户端类型 */
export enum ClientType {
  DISPLAY_MONITOR = 0,
  DISPLAY_MONITOR_WEB_BROWSER = 1,
  RESERVED_01 = 2,
  AUDIO = 3
}

/** b$l —— 客户端 OS 类型（服务端只认识这些值，鸿蒙端伪装成 ANDROID 以保持兼容） */
export enum OsType {
  UNKNOWN = 0,
  WINDOWS_NATIVE = 1,
  WINDOWS_UWP = 2,
  ANDROID = 3,
  IOS = 4
}

/** b$m —— 服务端 OS 类型（发现应答里的 serverOs 字段） */
export enum ServerOs {
  UNKNOWN = 0,
  WINDOWS_SERVER_R2_2008 = 1,
  WINDOWS_7 = 2,
  WINDOWS_SERVER_2012 = 3,
  WINDOWS_8_0 = 4,
  WINDOWS_SERVER_R2_2012 = 5,
  WINDOWS_8_1 = 6,
  WINDOWS_SERVER_2016 = 7,
  WINDOWS_10 = 8,
  WINDOWS_SERVER_2022 = 9,
  WINDOWS_11 = 10,
  WINDOWS_SERVER_2019 = 11,
  MACOS = 12
}

/** 发现应答标志位（f.a/b/c 使用；0x8 / 0x10 的具体语义仍待抓包确认） */
export class DiscoveryFlags {
  static readonly HAS_OS_NAME: number = 0x3;
  static readonly ENCRYPTED: number = 0x8;   // 推测：需要 TLS-PSK 加密连接
  static readonly PASSWORD: number = 0x10;  // 推测：需要连接密码
}

/* ---------------- 128 字节包头字段偏移（e 类静态常量） ---------------- */

export class HeaderOffset {
  static readonly TYPE: number = 0;        // e.b  int32
  static readonly PAYLOAD_LEN: number = 4; // e.c  int32
  static readonly F1: number = 8;          // e.d  int32，身份包固定 4
  static readonly F2: number = 12;         // e.e  int32，身份包固定 8
  static readonly CLIENT_TYPE: number = 16;// e.f  int32
  static readonly OS_TYPE: number = 20;    // e.g  int32
  static readonly COMPRESSION: number = 24;// e.h  int32
  static readonly COLOR_DEPTH: number = 28;// e.i  int32
  static readonly FPS: number = 32;        // e.j  int32
  static readonly SHORT_1: number = 36;    // e.k  int16
  static readonly SHORT_2: number = 38;    // e.l  int16
  static readonly SHORT_3: number = 44;    // e.m  int16
  static readonly FLOAT_OR_INT: number = 32;// e.a0 与 FPS 复用
  static readonly BYTE_1: number = 36;     // e.b0
  static readonly BYTE_2: number = 39;     // e.c0
  static readonly TAIL: number = 124;      // e.r  int32，包头最后一个字段
}

/* -------------------- 通用二进制工具 -------------------- */

/**
 * Buffer -> 独立 ArrayBuffer。
 * 2026-11-13 真机修正：入站 payload 是 subarray 视图（byteOffset 较大），
 * 鸿蒙 buffer 模块的 .buffer 属性语义与 Node 不一致，用
 * slice(byteOffset, byteOffset+len) 会切出【空 ArrayBuffer】，
 * 导致 createImageSource 返回 undefined / 原生解码拿不到数据。
 * 改为 TypedArray.set 按内容拷贝，对任何 byteOffset 语义都正确。
 */
export function toArrayBuffer(src: buffer.Buffer): ArrayBuffer {
  const out: ArrayBuffer = new ArrayBuffer(src.length);
  const dst: buffer.Buffer = buffer.from(out) as buffer.Buffer;
  src.copy(dst, 0, 0, src.length);
  return out;
}

export function fromArrayBuffer(src: ArrayBuffer): buffer.Buffer {
  return buffer.from(src) as buffer.Buffer;
}

/** 写 UTF-16LE 字符串（低位在前，高位补 0），超出长度自动截断 */
export function writeUtf16Le(dst: buffer.Buffer, offset: number, text: string, maxChars: number): void {
  const n: number = Math.min(text.length, maxChars);
  for (let i: number = 0; i < n; i++) {
    const code: number = text.charCodeAt(i);
    dst.writeUInt8(code & 0xFF, offset + i * 2);
    dst.writeUInt8((code >>> 8) & 0xFF, offset + i * 2 + 1);
  }
}

/** 读 UTF-16LE 字符串，遇 NUL 结束 */
export function readUtf16Le(src: buffer.Buffer, offset: number, byteLen: number): string {
  let result: string = '';
  for (let i: number = 0; i + 1 < byteLen; i += 2) {
    const code: number = src.readUInt16LE(offset + i);
    if (code === 0) {
      break;
    }
    result += String.fromCharCode(code);
  }
  return result.trim();
}

/** 构造一个空的 128 字节包头 */
export function newHeader(type: HeaderType, payloadLength: number): buffer.Buffer {
  const h: buffer.Buffer = buffer.alloc(HEADER_SIZE);
  h.writeInt32LE(type, HeaderOffset.TYPE);
  h.writeInt32LE(payloadLength, HeaderOffset.PAYLOAD_LEN);
  return h;
}

/** 拼接包头与载荷 */
export function joinPacket(header: buffer.Buffer, payload: buffer.Buffer): buffer.Buffer {
  const out: buffer.Buffer = buffer.alloc(header.length + payload.length);
  header.copy(out, 0);
  payload.copy(out, header.length);
  return out;
}

/* -------------------- 发现协议 -------------------- */

/** UDP 广播探测包：UTF-8 的 "SPACEDESK-NET-CLIENT\0" */
export function buildDiscoveryProbe(): ArrayBuffer {
  return toArrayBuffer(buffer.from(DISCOVERY_MAGIC, 'utf-8'));
}

/** 可作为连接目标的主机地址：排除 0.0.0.0 / 255.255.255.255 / 127.x（服务端应答包 IP 字段常为 0，需回落到 UDP 源地址） */
export function isUsableHostIp(s: string): boolean {
  if (!isIpV4(s)) {
    return false;
  }
  const parts: string[] = s.split('.');
  const o: number[] = parts.map((p: string): number => parseInt(p, 10));
  if (o[0] === 0 || o[0] === 127) {
    return false;
  }
  if (o[0] === 255 && o[1] === 255 && o[2] === 255 && o[3] === 255) {
    return false;
  }
  return true;
}

/** 解析 308 字节发现应答 */
export function parseDiscoveryReply(raw: ArrayBuffer, fallbackIp: string): DiscoveredServer | undefined {
  if (raw.byteLength < DISCOVERY_REPLY_SIZE) {
    return undefined;
  }
  const b: buffer.Buffer = buffer.from(new Uint8Array(raw)) as buffer.Buffer;
  const name: string = readUtf16Le(b, 0, 256);
  // IPv4 以 (a<<24|b<<16|c<<8|d) 的 uint32 小端写入，
  // 因此线上字节顺序是 [d, c, b, a]
  const a: number = b.readUInt8(259);
  const c2: number = b.readUInt8(258);
  const c3: number = b.readUInt8(257);
  const c4: number = b.readUInt8(256);
  const ip: string = `${a}.${c2}.${c3}.${c4}`;
  const port: number = b.readInt32LE(260);
  const serverOs: number = b.readInt32LE(264);
  const flags: number = b.readUInt32LE(280);

  const validIp: string = isUsableHostIp(ip) ? ip : (isUsableHostIp(fallbackIp) ? fallbackIp : '');
  if (validIp.length === 0) {
    // 包内地址与 UDP 源地址都不可用，无法作为连接目标
    return undefined;
  }
  return {
    name: name.length > 0 ? name : fallbackIp,
    ip: validIp,
    port: port > 0 && port < 65536 ? port : NET_PORT,
    serverOs: serverOs,
    flags: flags,
    encrypted: (flags & DiscoveryFlags.ENCRYPTED) !== 0,
    passwordRequired: (flags & DiscoveryFlags.PASSWORD) !== 0,
    osLabel: serverOsName(serverOs)
  };
}

export function isIpV4(s: string): boolean {
  const parts: string[] = s.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const p of parts) {
    if (p.length === 0 || p.length > 3) {
      return false;
    }
    for (let i: number = 0; i < p.length; i++) {
      const ch: string = p.charAt(i);
      if (ch < '0' || ch > '9') {
        return false;
      }
    }
    const n: number = Number.parseInt(p, 10);
    if (n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

export function serverOsName(os: number): string {
  switch (os) {
    case ServerOs.WINDOWS_7: return 'Windows 7';
    case ServerOs.WINDOWS_8_0: return 'Windows 8';
    case ServerOs.WINDOWS_8_1: return 'Windows 8.1';
    case ServerOs.WINDOWS_10: return 'Windows 10';
    case ServerOs.WINDOWS_11: return 'Windows 11';
    case ServerOs.WINDOWS_SERVER_2012: return 'Windows Server 2012';
    case ServerOs.WINDOWS_SERVER_R2_2012: return 'Windows Server 2012 R2';
    case ServerOs.WINDOWS_SERVER_2016: return 'Windows Server 2016';
    case ServerOs.WINDOWS_SERVER_2019: return 'Windows Server 2019';
    case ServerOs.WINDOWS_SERVER_2022: return 'Windows Server 2022';
    case ServerOs.WINDOWS_SERVER_R2_2008: return 'Windows Server 2008 R2';
    case ServerOs.MACOS: return 'macOS';
    default: return 'Windows';
  }
}

/** 发现到的服务端信息 */
export interface DiscoveredServer {
  name: string;
  ip: string;
  port: number;
  serverOs: number;
  flags: number;
  encrypted: boolean;
  passwordRequired: boolean;
  osLabel: string;
}

/* -------------------- 会话握手 -------------------- */

export interface IdentificationOptions {
  instanceId: string;
  deviceName: string;
  compression: Compression;
  fps: number;
  colorDepth: number;
}

/**
 * 构造身份识别报文：128B 包头 + 334B 身份数据。
 * 对应 k2.c()，客户端类型 DISPLAY_MONITOR，OS 类型 ANDROID（兼容性考虑）。
 */
export function buildIdentification(opt: IdentificationOptions): ArrayBuffer {
  const h: buffer.Buffer = newHeader(HeaderType.IDENTIFICATION, IDENT_PAYLOAD_SIZE);
  h.writeInt32LE(4, HeaderOffset.F1);
  h.writeInt32LE(8, HeaderOffset.F2);
  h.writeInt32LE(ClientType.DISPLAY_MONITOR, HeaderOffset.CLIENT_TYPE);
  h.writeInt32LE(OsType.ANDROID, HeaderOffset.OS_TYPE);
  h.writeInt32LE(opt.compression, HeaderOffset.COMPRESSION);
  h.writeInt32LE(opt.colorDepth, HeaderOffset.COLOR_DEPTH);
  h.writeInt32LE(opt.fps > 0 ? opt.fps : 30, HeaderOffset.FPS);

  // d.a(): 0..76 为 InstanceID（39 个 UTF-16LE 字符），78..332 为设备名
  const payload: buffer.Buffer = buffer.alloc(IDENT_PAYLOAD_SIZE);
  writeUtf16Le(payload, 0, opt.instanceId, 39);
  writeUtf16Le(payload, 78, opt.deviceName, 128);
  return toArrayBuffer(joinPacket(h, payload));
}

/** 断开连接报文，对应 k2.b(int reason) */
export function buildDisconnect(reason: number): ArrayBuffer {
  // k2.b(): A(0) -> payloadLen=0, B(reason) -> 写入 e.f0 = 8
  const h: buffer.Buffer = newHeader(HeaderType.DISCONNECT, 0);
  h.writeInt32LE(reason, 8);
  return toArrayBuffer(h);
}

/** 心跳，对应 k2 的 PING */
export function buildPing(): ArrayBuffer {
  return toArrayBuffer(newHeader(HeaderType.PING, 0));
}

/** 解析收到的包头（长度不足返回 undefined） */
export interface PacketHeaderView {
  type: number;
  payloadLength: number;
  compression: number;
  fps: number;
  colorDepth: number;
}

export function parseHeader(raw: buffer.Buffer, offset: number): PacketHeaderView | undefined {
  if (raw.length - offset < HEADER_SIZE) {
    return undefined;
  }
  return {
    type: raw.readInt32LE(offset + HeaderOffset.TYPE),
    payloadLength: raw.readInt32LE(offset + HeaderOffset.PAYLOAD_LEN),
    compression: raw.readInt32LE(offset + HeaderOffset.COMPRESSION),
    fps: raw.readInt32LE(offset + HeaderOffset.FPS),
    colorDepth: raw.readInt32LE(offset + HeaderOffset.COLOR_DEPTH)
  };
}

/* -------------------- 输入事件（待抓包复核） -------------------- */

/**
 * 输入事件载荷内部布局尚未从字节码完整还原（涉及 SAMotionEvent 的私有序列化）。
 * 这里按包头类型 + 归一化坐标给出可扩展骨架；接入真实抓包结果后只需替换本函数。
 */
export function buildInputEvent(type: HeaderType, x: number, y: number,
                                action: number, extra: number): ArrayBuffer {
  const payload: buffer.Buffer = buffer.alloc(24);
  payload.writeInt32LE(action, 0);
  // 归一化坐标放大 1000 倍以整数传输（真实协议需按抓包结果替换）
  payload.writeInt32LE(Math.round(x * 1000), 4);
  payload.writeInt32LE(Math.round(y * 1000), 8);
  payload.writeInt32LE(extra, 12);
  payload.writeInt32LE(0, 16);
  payload.writeInt32LE(0, 20);
  return toArrayBuffer(joinPacket(newHeader(type, payload.length), payload));
}

/**
 * TCP 是字节流，必须自己按 [128B 头][payloadLength B 载荷] 组帧。
 * 返回完整报文列表，并把未收完的尾巴留在缓冲区里。
 */
export class StreamAssembler {
  private pending: buffer.Buffer = buffer.alloc(0);

  push(chunk: ArrayBuffer): ParsedPacket[] {
    const incoming: buffer.Buffer = buffer.from(new Uint8Array(chunk)) as buffer.Buffer;
    this.pending = this.pending.length === 0
      ? incoming
      : buffer.concat([this.pending, incoming]) as buffer.Buffer;

    const packets: ParsedPacket[] = [];
    while (this.pending.length >= HEADER_SIZE) {
      const h: PacketHeaderView | undefined = parseHeader(this.pending, 0);
      if (h === undefined) {
        break;
      }
      const total: number = HEADER_SIZE + h.payloadLength;
      if (total < HEADER_SIZE || total > 64 * 1024 * 1024) {
        // 长度异常，丢弃一个字节重新同步
        this.pending = this.pending.subarray(1) as buffer.Buffer;
        continue;
      }
      if (this.pending.length < total) {
        break;
      }
      const rawHeader: buffer.Buffer = buffer.from(this.pending.subarray(0, HEADER_SIZE)) as buffer.Buffer;
      const payload: buffer.Buffer = this.pending.subarray(HEADER_SIZE, total) as buffer.Buffer;
      packets.push({ header: h, rawHeader: rawHeader, payload: payload });
      this.pending = this.pending.subarray(total) as buffer.Buffer;
    }
    return packets;
  }

  reset(): void {
    this.pending = buffer.alloc(0);
  }
}

export interface ParsedPacket {
  header: PacketHeaderView;
  /** 未经解析的 128 字节包头，供帧元信息等类型相关字段使用 */
  rawHeader: buffer.Buffer;
  payload: buffer.Buffer;
}
