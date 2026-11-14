// H.264 解码桥（OH_AVCodec → ArkTS）
//
// 服务器在 H.264 模式下每帧发一个 frag=0 的完整 Annex-B 包（实测头是 00 00 00 01，
// 首帧带 SPS/PPS，后续是 SEI + 切片），这里喂给硬件解码器，
// 解码出的 YUV 转 RGBA 后通过线程安全函数回调给 ArkTS 上屏。

#include <napi/native_api.h>
#include <hilog/log.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>

#include <mutex>
#include <deque>
#include <vector>
#include <cstring>
#include <cstdint>
#include <utility>

#define TAG "spacedesk_h264"
#define LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0001, TAG, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0001, TAG, fmt, ##__VA_ARGS__)

namespace {

constexpr int32_t FMT_YUV420 = 1;
constexpr int32_t FMT_NV12 = 2;
constexpr int32_t FMT_NV21 = 3;

struct FrameOut {
  int32_t width;
  int32_t height;
  std::vector<uint8_t> rgba;
};

struct Decoder {
  OH_AVCodec *codec = nullptr;
  int32_t width = 0;
  int32_t height = 0;
  int32_t stride = 0;
  int32_t sliceHeight = 0;
  int32_t pixFmt = FMT_NV12;
  int32_t decoded = 0;
  int32_t errors = 0;
  std::mutex mtx;
  std::deque<std::vector<uint8_t>> pending;
  std::deque<std::pair<uint32_t, OH_AVBuffer *>> idle;
  napi_threadsafe_function tsfn = nullptr;
};

Decoder *gDecoder = nullptr;

inline uint8_t Clamp(int32_t v) {
  if (v < 0) return 0;
  if (v > 255) return 255;
  return static_cast<uint8_t>(v);
}

void YuvToRgba(const uint8_t *src, int32_t stride, int32_t sliceHeight,
               int32_t width, int32_t height, int32_t fmt, std::vector<uint8_t> &out) {
  out.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
  const int32_t ySize = stride * sliceHeight;
  const uint8_t *yPlane = src;
  const uint8_t *uvPlane = src + ySize;
  const uint8_t *vPlane = (fmt == FMT_YUV420) ? (src + ySize + (stride / 2) * (sliceHeight / 2)) : nullptr;

  for (int32_t row = 0; row < height; row++) {
    const uint8_t *yRow = yPlane + row * stride;
    for (int32_t col = 0; col < width; col++) {
      int32_t u = 0;
      int32_t v = 0;
      if (fmt == FMT_YUV420) {
        u = static_cast<int32_t>(uvPlane[(row / 2) * (stride / 2) + (col / 2)]) - 128;
        v = static_cast<int32_t>(vPlane[(row / 2) * (stride / 2) + (col / 2)]) - 128;
      } else {
        const int32_t uvIndex = (row / 2) * stride + (col / 2) * 2;
        if (fmt == FMT_NV21) {
          v = static_cast<int32_t>(uvPlane[uvIndex]) - 128;
          u = static_cast<int32_t>(uvPlane[uvIndex + 1]) - 128;
        } else {
          u = static_cast<int32_t>(uvPlane[uvIndex]) - 128;
          v = static_cast<int32_t>(uvPlane[uvIndex + 1]) - 128;
        }
      }
      const int32_t yy = static_cast<int32_t>(yRow[col]) - 16;
      const int32_t r = (298 * yy + 409 * v + 128) >> 8;
      const int32_t g = (298 * yy - 208 * v - 100 * u + 128) >> 8;
      const int32_t b = (298 * yy + 516 * u + 128) >> 8;
      const size_t idx = (static_cast<size_t>(row) * static_cast<size_t>(width) + col) * 4;
      out[idx] = Clamp(r);
      out[idx + 1] = Clamp(g);
      out[idx + 2] = Clamp(b);
      out[idx + 3] = 255;
    }
  }
}

void CallJs(napi_env env, napi_value jsCb, void *context, void *data) {
  FrameOut *frame = static_cast<FrameOut *>(data);
  if (env == nullptr || jsCb == nullptr || frame == nullptr) {
    delete frame;
    return;
  }
  void *raw = nullptr;
  napi_value buffer = nullptr;
  if (napi_create_arraybuffer(env, frame->rgba.size(), &raw, &buffer) == napi_ok && raw != nullptr) {
    memcpy(raw, frame->rgba.data(), frame->rgba.size());
    napi_value width = nullptr;
    napi_value height = nullptr;
    napi_create_int32(env, frame->width, &width);
    napi_create_int32(env, frame->height, &height);
    napi_value argv[3] = {buffer, width, height};
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCb, 3, argv, nullptr);
  }
  delete frame;
}

void RefreshOutputInfo(Decoder *d) {
  OH_AVFormat *fmt = OH_VideoDecoder_GetOutputDescription(d->codec);
  if (fmt == nullptr) {
    return;
  }
  int32_t value = 0;
  if (OH_AVFormat_GetIntValue(fmt, OH_MD_KEY_WIDTH, &value) && value > 0) {
    d->width = value;
  }
  if (OH_AVFormat_GetIntValue(fmt, OH_MD_KEY_HEIGHT, &value) && value > 0) {
    d->height = value;
  }
  if (OH_AVFormat_GetIntValue(fmt, OH_MD_KEY_VIDEO_STRIDE, &value) && value > 0) {
    d->stride = value;
  }
  if (OH_AVFormat_GetIntValue(fmt, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &value) && value > 0) {
    d->sliceHeight = value;
  }
  if (OH_AVFormat_GetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, &value) && value > 0) {
    d->pixFmt = value;
  }
  OH_AVFormat_Destroy(fmt);
  if (d->stride <= 0) {
    d->stride = d->width;
  }
  if (d->sliceHeight <= 0) {
    d->sliceHeight = d->height;
  }
}

void TrySend(Decoder *d) {
  while (true) {
    std::vector<uint8_t> au;
    std::pair<uint32_t, OH_AVBuffer *> slot;
    {
      std::lock_guard<std::mutex> lock(d->mtx);
      if (d->pending.empty() || d->idle.empty() || d->codec == nullptr) {
        return;
      }
      au = std::move(d->pending.front());
      d->pending.pop_front();
      slot = d->idle.front();
      d->idle.pop_front();
    }
    uint8_t *addr = OH_AVBuffer_GetAddr(slot.second);
    int32_t capacity = OH_AVBuffer_GetCapacity(slot.second);
    if (addr == nullptr || capacity <= 0) {
      continue;
    }
    int32_t size = static_cast<int32_t>(au.size());
    if (size > capacity) {
      size = capacity;
    }
    memcpy(addr, au.data(), static_cast<size_t>(size));
    OH_AVCodecBufferAttr attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = size;
    attr.offset = 0;
    attr.pts = 0;
    attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
    OH_AVBuffer_SetBufferAttr(slot.second, &attr);
    OH_VideoDecoder_PushInputBuffer(d->codec, slot.first);
  }
}

void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData) {
  Decoder *d = static_cast<Decoder *>(userData);
  if (d != nullptr) {
    d->errors++;
  }
  LOGE("decoder error %{public}d", errorCode);
}

void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
  Decoder *d = static_cast<Decoder *>(userData);
  if (d != nullptr && format != nullptr) {
    RefreshOutputInfo(d);
  }
}

void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
  Decoder *d = static_cast<Decoder *>(userData);
  if (d == nullptr || buffer == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(d->mtx);
    d->idle.emplace_back(index, buffer);
  }
  TrySend(d);
}

void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
  Decoder *d = static_cast<Decoder *>(userData);
  if (d == nullptr || buffer == nullptr) {
    return;
  }
  OH_AVCodecBufferAttr attr;
  memset(&attr, 0, sizeof(attr));
  OH_AVBuffer_GetBufferAttr(buffer, &attr);
  if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
    OH_VideoDecoder_FreeOutputBuffer(codec, index);
    return;
  }
  RefreshOutputInfo(d);
  uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
  if (addr != nullptr && d->width > 0 && d->height > 0) {
    FrameOut *frame = new FrameOut();
    frame->width = d->width;
    frame->height = d->height;
    YuvToRgba(addr, d->stride, d->sliceHeight, d->width, d->height, d->pixFmt, frame->rgba);
    d->decoded++;
    if (d->tsfn != nullptr) {
      napi_call_threadsafe_function(d->tsfn, frame, napi_tsfn_nonblocking);
    } else {
      delete frame;
    }
  }
  OH_VideoDecoder_FreeOutputBuffer(codec, index);
}

void DestroyDecoder(Decoder *d) {
  if (d == nullptr) {
    return;
  }
  if (d->codec != nullptr) {
    OH_VideoDecoder_Stop(d->codec);
    OH_VideoDecoder_Destroy(d->codec);
    d->codec = nullptr;
  }
  if (d->tsfn != nullptr) {
    napi_release_threadsafe_function(d->tsfn, napi_tsfn_release);
    d->tsfn = nullptr;
  }
  {
    std::lock_guard<std::mutex> lock(d->mtx);
    d->pending.clear();
    d->idle.clear();
  }
  delete d;
}

napi_value Init(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  napi_value falseValue = nullptr;
  napi_get_boolean(env, false, &falseValue);
  if (argc < 3) {
    return falseValue;
  }
  int32_t width = 0;
  int32_t height = 0;
  napi_get_value_int32(env, argv[0], &width);
  napi_get_value_int32(env, argv[1], &height);
  if (width <= 0 || height <= 0) {
    return falseValue;
  }
  if (gDecoder != nullptr) {
    DestroyDecoder(gDecoder);
    gDecoder = nullptr;
  }

  Decoder *d = new Decoder();
  d->width = width;
  d->height = height;
  d->stride = width;
  d->sliceHeight = height;

  napi_value name = nullptr;
  napi_create_string_utf8(env, "spacedeskH264Callback", NAPI_AUTO_LENGTH, &name);
  napi_status st = napi_create_threadsafe_function(env, argv[2], nullptr, name, 12, 2, nullptr, nullptr,
                                                   nullptr, CallJs, &d->tsfn);
  if (st != napi_ok) {
    delete d;
    return falseValue;
  }
  napi_unref_threadsafe_function(env, d->tsfn);

  d->codec = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
  if (d->codec == nullptr) {
    LOGE("create decoder failed");
    DestroyDecoder(d);
    return falseValue;
  }

  OH_AVCodecCallback cb;
  cb.onError = OnError;
  cb.onStreamChanged = OnStreamChanged;
  cb.onNeedInputBuffer = OnNeedInputBuffer;
  cb.onNewOutputBuffer = OnNewOutputBuffer;
  OH_VideoDecoder_RegisterCallback(d->codec, cb, d);

  OH_AVFormat *fmt = OH_AVFormat_Create();
  OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, width);
  OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, height);
  OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, FMT_NV12);
  OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_FRAME_RATE, 30);
  OH_AVErrCode ret = OH_VideoDecoder_Configure(d->codec, fmt);
  OH_AVFormat_Destroy(fmt);
  if (ret != AV_ERR_OK) {
    LOGE("configure failed %{public}d", ret);
    DestroyDecoder(d);
    return falseValue;
  }
  if (OH_VideoDecoder_Prepare(d->codec) != AV_ERR_OK || OH_VideoDecoder_Start(d->codec) != AV_ERR_OK) {
    LOGE("prepare/start failed");
    DestroyDecoder(d);
    return falseValue;
  }

  gDecoder = d;
  napi_value trueValue = nullptr;
  napi_get_boolean(env, true, &trueValue);
  return trueValue;
}

napi_value Push(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  napi_value undefined = nullptr;
  napi_get_undefined(env, &undefined);
  Decoder *d = gDecoder;
  if (d == nullptr || argv[0] == nullptr) {
    return undefined;
  }
  void *data = nullptr;
  size_t length = 0;
  napi_get_arraybuffer_info(env, argv[0], &data, &length);
  if (data == nullptr || length == 0) {
    return undefined;
  }
  std::vector<uint8_t> copy(static_cast<uint8_t *>(data), static_cast<uint8_t *>(data) + length);
  {
    std::lock_guard<std::mutex> lock(d->mtx);
    d->pending.push_back(std::move(copy));
    if (d->pending.size() > 8) {
      d->pending.pop_front();
    }
  }
  TrySend(d);
  return undefined;
}

napi_value Release(napi_env env, napi_callback_info info) {
  if (gDecoder != nullptr) {
    DestroyDecoder(gDecoder);
    gDecoder = nullptr;
  }
  napi_value undefined = nullptr;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value Stats(napi_env env, napi_callback_info info) {
  Decoder *d = gDecoder;
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  auto setInt = [&](const char *key, int32_t value) {
    napi_value v = nullptr;
    napi_create_int32(env, value, &v);
    napi_set_named_property(env, obj, key, v);
  };
  if (d == nullptr) {
    setInt("decoded", 0);
    setInt("errors", 0);
    setInt("width", 0);
    setInt("height", 0);
    setInt("stride", 0);
    setInt("sliceHeight", 0);
    setInt("pixelFormat", 0);
    setInt("pending", 0);
    setInt("idle", 0);
    return obj;
  }
  std::lock_guard<std::mutex> lock(d->mtx);
  setInt("decoded", d->decoded);
  setInt("errors", d->errors);
  setInt("width", d->width);
  setInt("height", d->height);
  setInt("stride", d->stride);
  setInt("sliceHeight", d->sliceHeight);
  setInt("pixelFormat", d->pixFmt);
  setInt("pending", static_cast<int32_t>(d->pending.size()));
  setInt("idle", static_cast<int32_t>(d->idle.size()));
  return obj;
}
}  // namespace

EXTERN_C_START
static napi_value InitModule(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    {"init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"push", nullptr, Push, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stats", nullptr, Stats, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module h264Module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = InitModule,
    .nm_modname = "h264dec",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule() {
  napi_module_register(&h264Module);
}
