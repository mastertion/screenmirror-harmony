export interface DecodedFrame {
  width: number;
  height: number;
  data: ArrayBuffer;
}

/** 初始化 OH_AVCodec H.264 解码器（宽、高来自画面包头或设置） */
export const init: (width: number, height: number) => boolean;
/** 送入一段 H.264 Annex-B 码流 */
export const push: (data: ArrayBuffer) => boolean;
/** 轮询最新解码帧，无新帧时 data.byteLength === 0 */
export const poll: () => DecodedFrame;
/** 同步解码 JPEG → RGBA_8888 像素（stb_image 实现）；失败时 width === 0 */
export const decodeJpeg: (data: ArrayBuffer) => DecodedFrame;
/** 释放解码器 */
export const release: () => void;
