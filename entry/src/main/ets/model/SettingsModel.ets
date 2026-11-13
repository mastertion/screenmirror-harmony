/**
 * 设置项存储。key 名沿用原 APK res/xml/pref_*.xml 中的 key_*，
 * 便于和逆向出的 PreferenceScreen 结构一一对应。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Compression } from '../common/Protocol';

export const PREF_STORE: string = 'screenmirror_settings';

export class SettingsModel {
  private store: preferences.Preferences | undefined = undefined;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, PREF_STORE);
  }

  private ready(): boolean {
    return this.store !== undefined;
  }

  getBool(key: string, def: boolean): boolean {
    if (!this.ready()) {
      return def;
    }
    return this.store!.getSync(key, def) as boolean;
  }

  getNumber(key: string, def: number): number {
    if (!this.ready()) {
      return def;
    }
    return this.store!.getSync(key, def) as number;
  }

  getString(key: string, def: string): string {
    if (!this.ready()) {
      return def;
    }
    return this.store!.getSync(key, def) as string;
  }

  async putBool(key: string, value: boolean): Promise<void> {
    if (!this.ready()) {
      return;
    }
    await this.store!.put(key, value);
    await this.store!.flush();
  }

  async putNumber(key: string, value: number): Promise<void> {
    if (!this.ready()) {
      return;
    }
    await this.store!.put(key, value);
    await this.store!.flush();
  }

  async putString(key: string, value: string): Promise<void> {
    if (!this.ready()) {
      return;
    }
    await this.store!.put(key, value);
    await this.store!.flush();
  }

  /** 画质与性能 */
  getCompression(): Compression {
    const v: number = this.getNumber('key_compression_type_string', Compression.CHOOSE_BEST);
    return v as Compression;
  }

  getFps(): number {
    return this.getNumber('key_fps', 30);
  }

  getQuality(): number {
    return this.getNumber('key_compression_quality', 60);
  }

  getColorDepth(): number {
    return this.getNumber('key_color_depth', 6);
  }

  /** 连接 */
  getConnectTimeout(): number {
    return this.getNumber('key_con_watcher_timeout_delta', 20000);
  }

  getAutoConnectIp(): string {
    return this.getString('key_auto_connect_ip', '');
  }

  /** 设备标识 */
  getInstanceId(): string {
    let id: string = this.getString('harmony_instance_id', '');
    if (id.length === 0) {
      id = 'HM-' + Date.now().toString(36).toUpperCase();
      this.putString('harmony_instance_id', id);
    }
    return id;
  }
}

export const settings: SettingsModel = new SettingsModel();
