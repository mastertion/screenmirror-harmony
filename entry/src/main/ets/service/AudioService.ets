/**
 * 远程音频播放服务
 *
 * 原 Android 端为 SAAudioRenderer（AudioTrack），对应独立 TCP 通道的 AUDIO 类型报文。
 * 这里用 HarmonyOS @kit.AudioKit 的 AudioRenderer 播放 PCM，参数自适应收到的音频头。
 */
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AudioChunk } from '../common/ProtocolEx';

export class AudioService {
  private renderer: audio.AudioRenderer | undefined = undefined;
  private sampleRate: number = 0;
  private channels: number = 0;
  private volume: number = 1.0;
  private enabled: boolean = true;
  private writing: boolean = false;
  private dropped: number = 0;
  private playedBytes: number = 0;

  setEnabled(on: boolean): void {
    this.enabled = on;
    if (!on) {
      this.close();
    }
  }

  setVolume(v: number): void {
    this.volume = Math.max(0, Math.min(1, v));
    if (this.renderer !== undefined) {
      try {
        this.renderer.setVolume(this.volume);
      } catch (e) {
        // 音量设置失败不影响播放
      }
    }
  }

  /** 收到一段音频数据；格式变化时自动重建渲染器 */
  push(chunk: AudioChunk): void {
    if (!this.enabled || chunk.pcm.byteLength === 0) {
      return;
    }
    if (this.renderer === undefined || chunk.sampleRate !== this.sampleRate ||
        chunk.channels !== this.channels) {
      this.rebuild(chunk.sampleRate, chunk.channels);
      return; // 首包用于确定格式，下一包开始真正写入
    }
    this.write(chunk.pcm);
  }

  private rebuild(sampleRate: number, channels: number): void {
    this.sampleRate = sampleRate;
    this.channels = channels;
    this.close();
    try {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: sampleRate as audio.AudioSamplingRate,
        channels: (channels === 1 ? audio.AudioChannel.CHANNEL_1 : audio.AudioChannel.CHANNEL_2),
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };
      const rendererInfo: audio.AudioRendererInfo = {
        content: audio.ContentType.CONTENT_TYPE_MUSIC,
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
      audio.createAudioRenderer({ streamInfo: streamInfo, rendererInfo: rendererInfo })
        .then((r: audio.AudioRenderer): void => {
          this.renderer = r;
          r.setVolume(this.volume);
          r.start().catch((e: BusinessError): void => {
            console.warn(`音频启动失败: ${e.message}`);
          });
        })
        .catch((e: BusinessError): void => {
          console.warn(`音频渲染器创建失败: ${e.message}`);
        });
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`音频初始化异常: ${err.message}`);
    }
  }

  private write(data: ArrayBuffer): void {
    if (this.renderer === undefined || this.writing) {
      this.dropped++;
      return;
    }
    this.writing = true;
    this.renderer.write(data)
      .then((n: number): void => {
        this.playedBytes += n;
        this.writing = false;
      })
      .catch((): void => {
        this.dropped++;
        this.writing = false;
      });
  }

  close(): void {
    if (this.renderer !== undefined) {
      try {
        this.renderer.stop();
        this.releaseQuietly(this.renderer);
      } catch (e) {
        // 已释放
      }
      this.renderer = undefined;
    }
  }

  private releaseQuietly(r: audio.AudioRenderer): void {
    try {
      r.release();
    } catch (e) {
      // 忽略
    }
  }

  getPlayedBytes(): number {
    return this.playedBytes;
  }

  getDropped(): number {
    return this.dropped;
  }
}

export const audioService: AudioService = new AudioService();
