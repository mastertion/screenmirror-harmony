/*
 * H.264 解码桥接层（HarmonyOS OH_AVCodec + NAPI）
 *
 * 设计说明：
 *  - OH_AVCodec 是异步回调模型，回调发生在解码服务线程；
 *  - ArkTS 侧通过 poll() 轮询取回已转成 RGBA_8888 的最新帧，
 *    避免线程安全函数（TSFN）与 ArkTS 线程模型耦合；
 *  - 输出按 NV12 处理（OH_AVCodec 默认 YUV420 semiplanar），
 *    stride 由 onStreamChanged 下发的 OH_MD_KEY_VIDEO_STRIDE 决定；
 *  - SPS/PPS 帧用 AVCODEC_BUFFER_FLAGS_CODEC_DATA 标记送进去。
 *
 * 该模块只在 H.264 编码模式下使用，MJPEG / 原始位图走 ArkTS 侧系统解码器。
 */
#include <napi/native_api.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <hilog/log.h>

#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

/* stb_image：单头文件 JPEG/PNG 解码器（public domain）。
 * 用于 MJPEG 条带解码——2026-11-13 真机验证系统 image 框架对
 * spacedesk 服务端的标准 baseline JPEG 解码失败（Create PixelMap error），
 * 原生 stb 解码不依赖系统编解码插件，保证可用。 */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#include "stb_image.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x5D30
#define LOG_TAG "SpacedeskH264"

namespace {

struct InputSlot {
    uint32_t index;
    OH_AVBuffer *buffer;
};

struct RgbaFrame {
    int width;
    int height;
    std::vector<uint8_t> pixels;
};

class H264Decoder {
public:
    static H264Decoder &Instance()
    {
        static H264Decoder inst;
        return inst;
    }

    bool Init(int width, int height)
    {
        Release();
        {
            std::lock_guard<std::mutex> lk(mutex_);
            width_ = width > 0 ? width : 1920;
            height_ = height > 0 ? height : 1080;
            stride_ = width_;
        }
        OH_AVCodec *codec = OH_VideoDecoder_CreateByMime("video/avc");
        if (codec == nullptr) {
            OH_LOG_ERROR(LOG_APP, "create decoder failed");
            return false;
        }
        int w = width > 0 ? width : 1920;
        int h = height > 0 ? height : 1080;
        OH_AVFormat *fmt = OH_AVFormat_Create();
        OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, w);
        OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, h);
        OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
        OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_FRAME_RATE, 30);
        OH_AVErrCode ret = OH_VideoDecoder_Configure(codec, fmt);
        OH_AVFormat_Destroy(fmt);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "configure failed: %{public}d", ret);
            OH_VideoDecoder_Destroy(codec);
            return false;
        }
        OH_AVCodecCallback cb = {OnError, OnStreamChanged, OnNeedInputBuffer, OnNewOutputBuffer};
        ret = OH_VideoDecoder_RegisterCallback(codec, cb, this);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "register callback failed: %{public}d", ret);
            OH_VideoDecoder_Destroy(codec);
            return false;
        }
        // 在 Prepare/Start 之前登记，保证回调到达时状态已就绪
        {
            std::lock_guard<std::mutex> lk(mutex_);
            codec_ = codec;
            ready_ = true;
        }
        ret = OH_VideoDecoder_Prepare(codec);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "prepare failed: %{public}d", ret);
            Release();
            return false;
        }
        ret = OH_VideoDecoder_Start(codec);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "start failed: %{public}d", ret);
            Release();
            return false;
        }
        return true;
    }

    /** 从 ArkTS 送入一段 Annex-B 码流 */
    void Push(const uint8_t *data, size_t len)
    {
        if (data == nullptr || len == 0) {
            return;
        }
        OH_AVBuffer *buffer = nullptr;
        uint32_t index = 0;
        {
            std::lock_guard<std::mutex> lk(mutex_);
            if (!ready_ || codec_ == nullptr) {
                return;
            }
            pending_.emplace_back(data, data + len);
            while (pending_.size() > 8) {
                pending_.pop_front();
            }
            if (inputSlots_.empty()) {
                return;
            }
            InputSlot slot = inputSlots_.front();
            inputSlots_.pop_front();
            buffer = slot.buffer;
            index = slot.index;
        }
        FeedOne(buffer, index);
    }

    /** 取回最新的 RGBA 帧，没有新帧时返回空 */
    void Poll(RgbaFrame &out)
    {
        std::lock_guard<std::mutex> lk(mutex_);
        if (latest_.pixels.empty()) {
            return;
        }
        out.width = latest_.width;
        out.height = latest_.height;
        out.pixels.swap(latest_.pixels);
        latest_ = RgbaFrame();
    }

    void Release()
    {
        OH_AVCodec *codec = nullptr;
        {
            std::lock_guard<std::mutex> lk(mutex_);
            ready_ = false;
            codec = codec_;
            codec_ = nullptr;
            inputSlots_.clear();
            pending_.clear();
            latest_ = RgbaFrame();
        }
        // 停止/销毁必须在锁外调用，避免与解码服务回调互锁
        if (codec != nullptr) {
            OH_VideoDecoder_Stop(codec);
            OH_VideoDecoder_Destroy(codec);
        }
    }

private:
    void FeedOne(OH_AVBuffer *buffer, uint32_t index)
    {
        std::vector<uint8_t> frame;
        {
            std::lock_guard<std::mutex> lk(mutex_);
            if (pending_.empty() || !ready_ || codec_ == nullptr) {
                return;
            }
            frame.swap(pending_.front());
            pending_.pop_front();
        }
        uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
        int32_t cap = OH_AVBuffer_GetCapacity(buffer);
        if (addr == nullptr || cap <= 0 || static_cast<size_t>(cap) < frame.size()) {
            return;
        }
        memcpy(addr, frame.data(), frame.size());
        uint32_t flags = AVCODEC_BUFFER_FLAGS_NONE;
        // Annex-B: 00 00 00 01 [SPS/PPS NAL]
        size_t nal = (frame.size() > 4 && frame[0] == 0 && frame[1] == 0 && frame[2] == 0 &&
                      frame[3] == 1) ? 4 : (frame.size() > 3 && frame[0] == 0 &&
                      frame[1] == 0 && frame[2] == 1 ? 3 : 0);
        if (nal > 0 && frame.size() > nal) {
            int nalType = frame[nal] & 0x1F;
            if (nalType == 7 || nalType == 8) {
                flags = AVCODEC_BUFFER_FLAGS_CODEC_DATA;
            }
        }
        static int64_t pts = 0;
        OH_AVCodecBufferAttr attr;
        attr.pts = pts++;
        attr.size = static_cast<int32_t>(frame.size());
        attr.offset = 0;
        attr.flags = flags;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(codec_, index);
        if (ret != AV_ERR_OK) {
            OH_LOG_WARN(LOG_APP, "push input failed: %{public}d", ret);
        }
    }

    static void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData)
    {
        (void)codec;
        (void)userData;
        OH_LOG_ERROR(LOG_APP, "decoder error: %{public}d", errorCode);
    }

    static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
    {
        (void)codec;
        H264Decoder *self = static_cast<H264Decoder *>(userData);
        if (self == nullptr || format == nullptr) {
            return;
        }
        int32_t w = 0, h = 0, stride = 0;
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_STRIDE, &stride);
        std::lock_guard<std::mutex> lk(self->mutex_);
        if (w > 0) { self->width_ = w; }
        if (h > 0) { self->height_ = h; }
        self->stride_ = stride > 0 ? stride : self->width_;
    }

    static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index,
                                  OH_AVBuffer *buffer, void *userData)
    {
        (void)codec;
        H264Decoder *self = static_cast<H264Decoder *>(userData);
        if (self == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lk(self->mutex_);
        if (!self->ready_) {
            return;
        }
        self->inputSlots_.push_back({index, buffer});
    }

    static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index,
                                  OH_AVBuffer *buffer, void *userData)
    {
        H264Decoder *self = static_cast<H264Decoder *>(userData);
        if (self == nullptr || buffer == nullptr) {
            return;
        }
        OH_AVCodecBufferAttr attr;
        if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && attr.size > 0) {
            uint8_t *src = OH_AVBuffer_GetAddr(buffer);
            int w = 0, h = 0, stride = 0;
            {
                std::lock_guard<std::mutex> lk(self->mutex_);
                w = self->width_;
                h = self->height_;
                stride = self->stride_ > 0 ? self->stride_ : w;
            }
            if (src != nullptr && w > 0 && h > 0) {
                std::vector<uint8_t> rgba(static_cast<size_t>(w) * h * 4);
                Nv12ToRgba(src, stride, w, h, rgba.data());
                std::lock_guard<std::mutex> lk(self->mutex_);
                self->latest_.width = w;
                self->latest_.height = h;
                self->latest_.pixels.swap(rgba);
            }
        }
        if (codec != nullptr) {
            OH_VideoDecoder_FreeOutputBuffer(codec, index);
        }
    }

    static void Nv12ToRgba(const uint8_t *src, int stride, int w, int h, uint8_t *dst)
    {
        const uint8_t *yPlane = src;
        const uint8_t *uvPlane = src + static_cast<size_t>(stride) * h;
        for (int j = 0; j < h; ++j) {
            const uint8_t *yRow = yPlane + static_cast<size_t>(stride) * j;
            const uint8_t *uvRow = uvPlane + static_cast<size_t>(stride) * (j / 2);
            for (int i = 0; i < w; ++i) {
                int C = static_cast<int>(yRow[i]) - 16;
                int D = static_cast<int>(uvRow[(i / 2) * 2]) - 128;
                int E = static_cast<int>(uvRow[(i / 2) * 2 + 1]) - 128;
                int r = (298 * C + 409 * E + 128) >> 8;
                int g = (298 * C - 100 * D - 208 * E + 128) >> 8;
                int b = (298 * C + 516 * D + 128) >> 8;
                size_t o = (static_cast<size_t>(j) * w + i) * 4;
                dst[o] = static_cast<uint8_t>(r < 0 ? 0 : (r > 255 ? 255 : r));
                dst[o + 1] = static_cast<uint8_t>(g < 0 ? 0 : (g > 255 ? 255 : g));
                dst[o + 2] = static_cast<uint8_t>(b < 0 ? 0 : (b > 255 ? 255 : b));
                dst[o + 3] = 255;
            }
        }
    }

    std::mutex mutex_;
    OH_AVCodec *codec_ = nullptr;
    bool ready_ = false;
    int width_ = 1920;
    int height_ = 1080;
    int stride_ = 1920;
    std::deque<InputSlot> inputSlots_;
    std::deque<std::vector<uint8_t>> pending_;
    RgbaFrame latest_;
};

napi_value JsInit(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t w = 1920, h = 1080;
    if (argc > 0) { napi_get_value_int32(env, argv[0], &w); }
    if (argc > 1) { napi_get_value_int32(env, argv[1], &h); }
    bool ok = H264Decoder::Instance().Init(w, h);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value JsPush(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    bool ok = false;
    if (argc > 0) {
        void *data = nullptr;
        size_t len = 0;
        if (napi_get_arraybuffer_info(env, argv[0], &data, &len) == napi_ok && data != nullptr) {
            H264Decoder::Instance().Push(static_cast<const uint8_t *>(data), len);
            ok = true;
        }
    }
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

/** 返回一个对象 { width, height, data }，无新帧时 data 长度为 0 */
napi_value JsPoll(napi_env env, napi_callback_info info)
{
    (void)info;
    RgbaFrame frame;
    H264Decoder::Instance().Poll(frame);
    napi_value obj;
    napi_create_object(env, &obj);
    napi_value w, h;
    napi_create_int32(env, frame.width, &w);
    napi_create_int32(env, frame.height, &h);
    napi_set_named_property(env, obj, "width", w);
    napi_set_named_property(env, obj, "height", h);
    void *out = nullptr;
    napi_value buf;
    napi_create_arraybuffer(env, frame.pixels.size(), &out, &buf);
    if (out != nullptr && !frame.pixels.empty()) {
        memcpy(out, frame.pixels.data(), frame.pixels.size());
    }
    napi_set_named_property(env, obj, "data", buf);
    return obj;
}

napi_value JsRelease(napi_env env, napi_callback_info info)
{
    (void)info;
    H264Decoder::Instance().Release();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/** decodeJpeg(data: ArrayBuffer) -> { width, height, data: RGBA_8888 }；失败时 width=0 */
napi_value JsDecodeJpeg(napi_env env, napi_callback_info info)
{
    napi_value obj;
    napi_create_object(env, &obj);

    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool ok = false;
    int w = 0, h = 0;
    std::vector<uint8_t> rgba;
    if (argc >= 1) {
        bool isAb = false;
        napi_is_arraybuffer(env, args[0], &isAb);
        if (isAb) {
            void *data = nullptr;
            size_t len = 0;
            napi_get_arraybuffer_info(env, args[0], &data, &len);
            if (data != nullptr && len > 4) {
                int comp = 0;
                stbi_uc *pixels = stbi_load_from_memory(
                    static_cast<const stbi_uc *>(data), static_cast<int>(len), &w, &h, &comp, 4);
                if (pixels != nullptr && w > 0 && h > 0) {
                    const size_t bytes = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
                    rgba.assign(pixels, pixels + bytes);
                    stbi_image_free(pixels);
                    ok = true;
                } else if (pixels != nullptr) {
                    stbi_image_free(pixels);
                }
            }
        }
    }

    napi_value nv, hv;
    napi_create_int32(env, ok ? w : 0, &nv);
    napi_create_int32(env, ok ? h : 0, &hv);
    napi_set_named_property(env, obj, "width", nv);
    napi_set_named_property(env, obj, "height", hv);

    void *out = nullptr;
    napi_value buf;
    const size_t bytes = rgba.size();
    napi_create_arraybuffer(env, bytes, &out, &buf);
    if (out != nullptr && bytes > 0) {
        memcpy(out, rgba.data(), bytes);
    }
    napi_set_named_property(env, obj, "data", buf);
    return obj;
}

napi_value Register(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"init", nullptr, JsInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"push", nullptr, JsPush, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"poll", nullptr, JsPoll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"decodeJpeg", nullptr, JsDecodeJpeg, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, JsRelease, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Register,
    .nm_modname = "spacedesk",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSpacedeskModule(void)
{
    napi_module_register(&g_module);
}
