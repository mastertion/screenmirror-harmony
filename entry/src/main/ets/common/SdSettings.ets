import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import {
  SdColorFormat,
  SdCompression,
  SdIdentConfig,
  SdLicenseType
} from './SdProtocol';

const STORE_NAME: string = 'spacedesk_settings';

/** 应用设置（持久化在 preferences 中） */
export class SdSettings {
  /** 客户端实例 ID，形如 {uuid}，服务器用它区分不同客户端 */
  clientId: string = '';
  /** 设备名，显示在 Windows 端的 spacedesk 控制面板 */
  deviceName: string = '';
  /** 帧率 */
  fps: number = 30;
  /** 请求的虚拟显示器宽度 */
  width: number = 1280;
  /** 请求的虚拟显示器高度 */
  height: number = 720;
  /** JPEG 质量（spacedesk 服务器侧压缩质量） */
  quality: number = 75;
  /** 0=1280x720，1=1920x1080，2=跟随屏幕 */
  resolutionMode: number = 0;
  /** 编码：3=MJPEG（兼容），4=H.264（低带宽，失败自动回退） */
  encoding: number = SdCompression.Mjpeg;
  /** 编码色彩深度（IDENT @28，TJSAMP）：0=4:4:4 最佳画质，1=4:2:2 均衡，2=4:2:0 最流畅 */
  colorDepth: number = SdColorFormat.Yuv420;
  /** 显示页是否显示统计条 */
  showStats: boolean = true;
  /** 屏幕方向：0=跟随系统（自动旋转），1=锁定横屏，2=锁定竖屏 */
  orientation: number = 1;
  /** 鼠标模式（触控板）：点按=左键，双指滑动=滚轮；关闭时触摸直连 Windows 触屏 */
  mouseMode: boolean = false;
  /** 接收电脑声音（独立音频连接，PCM 48kHz） */
  audioEnabled: boolean = false;
  /**
   * 【已废弃】旧版全局单密码，仅供 loadSettings 一次性迁移到 passwordBook 使用。
   * 现改为连接时按 IP 输入并保存，见 passwordBook / getIpPassword。
   */
  password: string = '';
  /**
   * 按服务器 IP 保存的连接密码，每行格式 `ip=hex`（等号后为空表示该 IP 用明文连接）。
   * 连接时按 IP 查询：无记录 → 弹窗询问；连接失败 → 清除该记录并重新询问；
   * 只有真正收到画面（密码正确）才写入，见 Display.onAuthSuccess。
   */
  passwordBook: string = '';
  autoReconnect: boolean = true;
  /** 启动时自动连接上次主机 */
  autoConnect: boolean = false;
  /** 上次连接的主机信息（配合 autoConnect 使用） */
  lastIp: string = '';
  lastPort: number = 0;
  lastName: string = '';
  /** 首启隐私提示是否已同意（上架合规要求） */
  privacyAgreed: boolean = false;
}

/** spacedesk 报文里的文本只能按单字节写入，这里做一次 ASCII 过滤 */
export function sanitizeAscii(text: string): string {
  let result = '';
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code >= 32 && code < 127) {
      result += text.charAt(i);
    }
  }
  if (result.length === 0) {
    return 'HarmonyOS Client';
  }
  return result;
}

export async function loadSettings(context: common.Context): Promise<SdSettings> {
  const store = await preferences.getPreferences(context, STORE_NAME);
  const settings = new SdSettings();

  settings.clientId = store.getSync('clientId', '') as string;
  if (settings.clientId.length === 0) {
    settings.clientId = `{${util.generateRandomUUID(false)}}`;
    await store.put('clientId', settings.clientId);
  }

  settings.deviceName = store.getSync('deviceName', '') as string;
  if (settings.deviceName.length === 0) {
    const model = deviceInfo.marketName.length > 0 ? deviceInfo.marketName : deviceInfo.productModel;
    settings.deviceName = `${model} (HarmonyOS)`;
    await store.put('deviceName', settings.deviceName);
  }

  settings.fps = store.getSync('fps', 30) as number;
  settings.width = store.getSync('width', 1280) as number;
  settings.height = store.getSync('height', 720) as number;
  settings.quality = store.getSync('quality', 75) as number;
  settings.resolutionMode = store.getSync('resolutionMode', 0) as number;
  // 当前版本固定 MJPEG：旧版可能持久化过 H264(4)，若沿用会让看门狗误判且与服务端口径不一致。
  settings.encoding = SdCompression.Mjpeg;
  settings.colorDepth = store.getSync('colorDepth', SdColorFormat.Yuv420) as number;
  settings.showStats = store.getSync('showStats', true) as boolean;
  settings.orientation = store.getSync('orientation', 1) as number;
  settings.mouseMode = store.getSync('mouseMode', false) as boolean;
  settings.audioEnabled = store.getSync('audioEnabled', false) as boolean;
  settings.password = store.getSync('password', '') as string;
  settings.passwordBook = store.getSync('passwordBook', '') as string;
  settings.autoReconnect = store.getSync('autoReconnect', true) as boolean;
  settings.autoConnect = store.getSync('autoConnect', false) as boolean;
  settings.lastIp = store.getSync('lastIp', '') as string;
  settings.lastPort = store.getSync('lastPort', 0) as number;
  settings.lastName = store.getSync('lastName', '') as string;
  settings.privacyAgreed = store.getSync('privacyAgreed', false) as boolean;
  // 迁移旧版「全局单密码」：绑定到最后一次连接的 IP，避免升级后需要重输
  // 注意必须放在 lastIp 读完之后，否则 lastIp 还是空串。
  if (settings.password.length > 0) {
    if (settings.passwordBook.length === 0 && settings.lastIp.length > 0) {
      settings.passwordBook = setIpPassword('', settings.lastIp, settings.password);
      await store.put('passwordBook', settings.passwordBook);
    }
    // 一次性迁移：清掉旧全局密码，避免用户在设置页清空记录后又被重新灌回来
    settings.password = '';
    await store.put('password', '');
  }
  await store.flush();
  return settings;
}

export async function saveSettings(context: common.Context, settings: SdSettings): Promise<void> {
  const store = await preferences.getPreferences(context, STORE_NAME);
  await store.put('fps', settings.fps);
  await store.put('width', settings.width);
  await store.put('height', settings.height);
  await store.put('quality', settings.quality);
  await store.put('resolutionMode', settings.resolutionMode);
  await store.put('encoding', settings.encoding);
  await store.put('colorDepth', settings.colorDepth);
  await store.put('showStats', settings.showStats);
  await store.put('orientation', settings.orientation);
  await store.put('mouseMode', settings.mouseMode);
  await store.put('audioEnabled', settings.audioEnabled);
  await store.put('password', settings.password);
  await store.put('passwordBook', settings.passwordBook);
  await store.put('autoReconnect', settings.autoReconnect);
  await store.put('autoConnect', settings.autoConnect);
  await store.put('lastIp', settings.lastIp);
  await store.put('lastPort', settings.lastPort);
  await store.put('lastName', settings.lastName);
  await store.put('privacyAgreed', settings.privacyAgreed);
  await store.flush();
}

/**
 * 按 IP 保存的连接密码本。
 * 每行 `ip=password`（password 为空表示「该 IP 用明文连接，别再问」）。
 * 用整行匹配而非 JSON，避免 ArkTS 严格模式下 Record/JSON.parse 的类型限制。
 */
export function getIpPassword(book: string, ip: string): string | undefined {
  if (book.length === 0 || ip.length === 0) {
    return undefined;
  }
  const lines = book.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const eq = line.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    if (line.substring(0, eq) === ip) {
      return line.substring(eq + 1);
    }
  }
  return undefined;
}

/** 写入/覆盖某个 IP 的密码，返回新的密码本 */
export function setIpPassword(book: string, ip: string, password: string): string {
  const kept: string[] = [];
  if (book.length > 0) {
    const lines = book.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const eq = line.indexOf('=');
      if (eq > 0 && line.substring(0, eq) === ip) {
        continue;
      }
      if (line.length > 0) {
        kept.push(line);
      }
    }
  }
  kept.push(`${ip}=${password}`);
  return kept.join('\n');
}

/** 列出所有已保存密码的 IP（设置页展示/清理用） */
export function listPasswordIps(book: string): string[] {
  const ips: string[] = [];
  if (book.length === 0) {
    return ips;
  }
  const lines = book.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const eq = lines[i].indexOf('=');
    if (eq > 0) {
      ips.push(lines[i].substring(0, eq));
    }
  }
  return ips;
}

/** 删除某个 IP 的密码记录（密码错误时调用，下次连接会重新询问） */
export function clearIpPassword(book: string, ip: string): string {
  const kept: string[] = [];
  if (book.length > 0) {
    const lines = book.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const eq = line.indexOf('=');
      if (eq > 0 && line.substring(0, eq) === ip) {
        continue;
      }
      if (line.length > 0) {
        kept.push(line);
      }
    }
  }
  return kept.join('\n');
}

/** 组装客户端标识参数 */
export function toIdentConfig(settings: SdSettings, width: number, height: number, fps: number): SdIdentConfig {
  const config = new SdIdentConfig();
  config.clientId = settings.clientId;
  config.deviceName = sanitizeAscii(settings.deviceName);
  config.fps = fps;
  config.width = width;
  config.height = height;
  config.quality = settings.quality;
  // 强制声明 MJPEG（Identification offset 24 / 36）。
  // 当前 H.264 原生解码链路是 OH_AVCodec → 逐像素 YUV→RGBA → ArrayBuffer → JS PixelMap，
  // 1080x2330@60fps 下：输入队列 >8 丢最旧包、tsfn 队列 12 非阻塞丢帧、AU 超过 buffer 容量被截断，
  // 任何一个 P 帧丢失都会让后续参考链断裂 → 块状割裂 / 残影；逐像素转换又是卡顿主因。
  // MJPEG 走系统 JPEG 解码 + 增量直绘，稳定且快。等原生链路优化完再开放 H.264。
  config.compression = SdCompression.Mjpeg;
  config.preferredCompression = SdCompression.Mjpeg;
  config.colorFormat = settings.colorDepth;
  config.rotation = width >= height ? 4 : 6;
  config.licenseType = SdLicenseType.NonCommercialBasic;
  return config;
}
