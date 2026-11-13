#include <curl/curl.h>

// curl_easy_setopt and curl_easy_getinfo are variadic, which Swift cannot call: one
// wrapper per kind of value.
static inline CURLcode ccurl_setopt_long(CURL *curl, CURLoption option, long value) {
    return curl_easy_setopt(curl, option, value);
}
static inline CURLcode ccurl_setopt_string(CURL *curl, CURLoption option, const char *value) {
    return curl_easy_setopt(curl, option, value);
}
static inline CURLcode ccurl_setopt_pointer(CURL *curl, CURLoption option, void *value) {
    return curl_easy_setopt(curl, option, value);
}
typedef size_t (*ccurl_write_function)(char *data, size_t size, size_t count, void *context);
static inline CURLcode ccurl_setopt_write_function(CURL *curl, ccurl_write_function function) {
    return curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, function);
}
typedef int (*ccurl_progress_function)(void *context, curl_off_t total, curl_off_t now, curl_off_t up_total, curl_off_t up_now);
static inline CURLcode ccurl_setopt_progress_function(CURL *curl, ccurl_progress_function function) {
    return curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, function);
}
static inline CURLcode ccurl_getinfo_long(CURL *curl, CURLINFO info, long *value) {
    return curl_easy_getinfo(curl, info, value);
}
static inline CURLcode ccurl_getinfo_string(CURL *curl, CURLINFO info, char **value) {
    return curl_easy_getinfo(curl, info, value);
}
