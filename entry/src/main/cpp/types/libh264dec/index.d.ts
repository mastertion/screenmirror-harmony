export interface H264Stats {
  decoded: number;
  errors: number;
  width: number;
  height: number;
  stride: number;
  sliceHeight: number;
  pixelFormat: number;
  pending: number;
  idle: number;
}

export const init: (width: number, height: number,
  callback: (rgba: ArrayBuffer, width: number, height: number) => void) => boolean;
export const push: (data: ArrayBuffer) => void;
export const release: () => void;
export const stats: () => H264Stats;
