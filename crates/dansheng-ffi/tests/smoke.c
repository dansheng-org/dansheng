/* Native ABI smoke test against a built shared library. Offline only. */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "dansheng.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

static void pause_poll(void) {
#ifdef _WIN32
    Sleep(5);
#else
    struct timespec delay = {0, 5000000};
    nanosleep(&delay, NULL);
#endif
}

static int poll_json(uint64_t operation, char *json, size_t capacity) {
    for (unsigned int attempt = 0; attempt < 3000; ++attempt) {
        dansheng_buffer buffer = {0};
        int32_t status = dansheng_poll(operation, &buffer);
        if (status == DANSHENG_PENDING) { pause_poll(); continue; }
        if (status != DANSHENG_OK || buffer.len >= capacity) return 0;
        memcpy(json, buffer.data, buffer.len);
        json[buffer.len] = '\0';
        if (dansheng_free(buffer.allocation) != DANSHENG_OK) return 0;
        if (dansheng_free(buffer.allocation) != DANSHENG_INVALID_HANDLE) return 0;
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2 || strchr(argv[1], '"') || strchr(argv[1], '\\')) {
        fputs("usage: ffi-c-smoke <fresh-test-directory-with-forward-slashes>\n", stderr);
        return 2;
    }
    char options[8192], json[8192];
    int length = snprintf(options, sizeof(options), "{\"data_dir\":\"%s\"}", argv[1]);
    if (length < 0 || (size_t)length >= sizeof(options)) return 3;
    uint64_t operation = 0;
    dansheng_buffer buffer = {0};
    if (dansheng_poll(UINT64_MAX, &buffer) != DANSHENG_INVALID_HANDLE) return 4;
    if (dansheng_open((const uint8_t *)options, (size_t)length, &operation) != DANSHENG_OK) return 5;
    if (!poll_json(operation, json, sizeof(json))) return 6;
    const char *engine_field = strstr(json, "\"engine\":");
    if (!engine_field) return 7;
    uint64_t engine = strtoull(engine_field + strlen("\"engine\":"), NULL, 10);
    if (!engine) return 8;
    if (dansheng_request(engine, (const uint8_t *)"{}", 2, &operation) != DANSHENG_INVALID_ARGUMENT) return 9;
    const char *request = "{\"id\":\"c-smoke\",\"method\":\"core.info\",\"params\":{}}";
    if (dansheng_request(engine, (const uint8_t *)request, strlen(request), &operation) != DANSHENG_OK) return 10;
    if (!poll_json(operation, json, sizeof(json)) || !strstr(json,"dansheng-core")) return 11;
    if (dansheng_close(engine, &operation) != DANSHENG_OK) return 12;
    if (!poll_json(operation, json, sizeof(json)) || !strstr(json,"\"closed\":true")) return 13;
    if (dansheng_close(engine, &operation) != DANSHENG_INVALID_HANDLE) return 14;
    puts("C ABI smoke passed");
    return 0;
}
