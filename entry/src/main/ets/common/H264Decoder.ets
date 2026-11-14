import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import h264dec from 'libh264dec.so';

/**
 * H.264 帧的解码桥：原生 OH_AVCodec 解码 → RGBA → PixelMap。
 *
 * 服务器实测：H.264 模式下每帧就是一个 frag=0 的完整 Annex-B 包，
 * 所以这里按“包 = 一帧”直接 push，解码完成后按整帧上屏。
 */
export class H264Decoder {
  private inited: boolean = false;
  private failed: boolean = false;
  private width: number = 0;
  private height: number = 0;
  private onPixelMap: ((pixelMap: image.PixelMap) => void) | undefined = undefined;

  isAvailable(): boolean {
    return this.inited && !this.failed;
  }

  init(width: number, height: number, onPixelMap: (pixelMap: image.PixelMap) => void): boolean {
    this.width = width;
    this.height = height;
    this.onPixelMap = onPixelMap;
    try {
      this.inited = (h264dec.init(width, height, (rgba: ArrayBuffer, w: number, h: number) => {
        this.toPixelMap(rgba, w, h);
      }) as boolean);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`h264 init failed: ${err.code} ${err.message}`);
      this.inited = false;
    }
    if (!this.inited) {
      this.failed = true;
    }
    return this.inited;
  }

  feed(payload: ArrayBuffer): void {
    if (!this.inited || this.failed) {
      return;
    }
    try {
      h264dec.push(payload);
    } catch (error) {
      const err = error as BusinessError;
      console.warn(`h264 push failed: ${err.code} ${err.message}`);
    }
  }

  private toPixelMap(rgba: ArrayBuffer, width: number, height: number): void {
    const options: image.InitializationOptions = {
      size: { width: width, height: height },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.OPAQUE,
      editable: false
    };
    image.createPixelMap(rgba, options).then((pixelMap: image.PixelMap) => {
      const callback = this.onPixelMap;
      if (callback !== undefined) {
        callback(pixelMap);
      } else {
        pixelMap.release();
      }
    }).catch((error: BusinessError) => {
      console.warn(`h264 createPixelMap failed: ${error.code}`);
    });
  }

  release(): void {
    if (this.inited) {
      try {
        h264dec.release();
      } catch (error) {
        console.warn(`h264 release failed: ${error}`);
      }
      this.inited = false;
    }
  }
}
