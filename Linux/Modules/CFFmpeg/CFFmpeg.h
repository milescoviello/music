#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/dict.h>
#include <errno.h>

// Macros Swift cannot see.
static inline int cffmpeg_error_again(void) { return AVERROR(EAGAIN); }
static inline int cffmpeg_error_eof(void) { return AVERROR_EOF; }
static inline int cffmpeg_error_exit(void) { return AVERROR_EXIT; }
static inline int cffmpeg_averror(int code) { return AVERROR(code); }
static inline int cffmpeg_error_http_server(void) { return AVERROR_HTTP_SERVER_ERROR; }
static inline int64_t cffmpeg_nopts(void) { return AV_NOPTS_VALUE; }
static inline AVRational cffmpeg_time_base_q(void) { return AV_TIME_BASE_Q; }

// A video frame scaled to packed RGB, for a GdkMemoryTexture. Through a void ** rather
// than SwsContext *, which FFmpeg 8 made a public struct and earlier versions keep opaque:
// Swift would see a different type on each. Colours follow the source: HD video is BT.709,
// which swscale does not assume.
static inline int cffmpeg_scale_rgb(void **context, const AVFrame *src, int width, int height,
                                    uint8_t *dst, int dst_stride) {
    struct SwsContext *old = (struct SwsContext *)*context;
    struct SwsContext *scaler = sws_getCachedContext(old, src->width, src->height, (enum AVPixelFormat)src->format,
                                                     width, height, AV_PIX_FMT_RGB24, SWS_BILINEAR,
                                                     NULL, NULL, NULL);
    if (!scaler) return -1;
    if (scaler != old) {
        int space = src->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_DEFAULT;
        sws_setColorspaceDetails(scaler, sws_getCoefficients(space), src->color_range == AVCOL_RANGE_JPEG,
                                 sws_getCoefficients(SWS_CS_DEFAULT), 1, 0, 1 << 16, 1 << 16);
    }
    *context = scaler;
    uint8_t *planes[4] = { dst, NULL, NULL, NULL };
    int strides[4] = { dst_stride, 0, 0, 0 };
    return sws_scale(scaler, (const uint8_t *const *)src->data, src->linesize, 0, src->height, planes, strides);
}

static inline void cffmpeg_scale_free(void **context) {
    sws_freeContext((struct SwsContext *)*context);
    *context = NULL;
}

