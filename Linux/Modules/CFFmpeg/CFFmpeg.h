#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/dict.h>
#include <errno.h>

// Macros Swift cannot see.
static inline int cffmpeg_error_again(void) { return AVERROR(EAGAIN); }
static inline int cffmpeg_error_eof(void) { return AVERROR_EOF; }
static inline int cffmpeg_error_exit(void) { return AVERROR_EXIT; }
static inline int64_t cffmpeg_nopts(void) { return AV_NOPTS_VALUE; }
static inline AVRational cffmpeg_time_base_q(void) { return AV_TIME_BASE_Q; }
