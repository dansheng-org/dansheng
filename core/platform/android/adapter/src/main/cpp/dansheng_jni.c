/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <jni.h>
#include "dansheng.h"

static void fail(JNIEnv *env) {
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (cls) (*env)->ThrowNew(env, cls, "dansheng ABI operation failed");
}
static jbyteArray poll_buffer(JNIEnv *env, uint64_t handle, int platform) {
    dansheng_buffer b = {0};
    int32_t status = platform ? dansheng_platform_poll(handle, &b) : dansheng_poll(handle, &b);
    if (status == DANSHENG_PENDING) return NULL;
    if (status != DANSHENG_OK) { fail(env); return NULL; }
    jbyteArray out = NULL;
    if (b.len <= 8 * 1024 * 1024) {
        out = (*env)->NewByteArray(env, (jsize)b.len);
        if (out) (*env)->SetByteArrayRegion(env, out, 0, (jsize)b.len, (const jbyte *)b.data);
    }
    int32_t freed = dansheng_free(b.allocation);
    if (!out || freed != DANSHENG_OK) fail(env);
    return out;
}
#define JNI(name) Java_org_dansheng_android_NativeCore_##name
JNIEXPORT jlong JNICALL JNI(open)(JNIEnv *env, jobject self, jbyteArray input) {
    (void)self; if (!input) { fail(env); return 0; }
    jsize len = (*env)->GetArrayLength(env, input);
    if (len > 8 * 1024 * 1024) { fail(env); return 0; }
    jbyte *bytes = (*env)->GetByteArrayElements(env, input, NULL); if (!bytes) return 0;
    uint64_t op = 0; int32_t status = dansheng_open((uint8_t *)bytes, (size_t)len, &op);
    (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT);
    if (status != DANSHENG_OK) fail(env); return (jlong)op;
}
JNIEXPORT jlong JNICALL JNI(request)(JNIEnv *env, jobject self, jlong engine, jbyteArray input) {
    (void)self; if (!input) { fail(env); return 0; }
    jsize len = (*env)->GetArrayLength(env, input);
    if (len > 8 * 1024 * 1024) { fail(env); return 0; }
    jbyte *bytes = (*env)->GetByteArrayElements(env, input, NULL); if (!bytes) return 0;
    uint64_t op = 0; int32_t status = dansheng_request((uint64_t)engine, (uint8_t *)bytes, (size_t)len, &op);
    (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT);
    if (status != DANSHENG_OK) fail(env); return (jlong)op;
}
JNIEXPORT jbyteArray JNICALL JNI(poll)(JNIEnv *e, jobject s, jlong op) { (void)s; return poll_buffer(e, (uint64_t)op, 0); }
JNIEXPORT jint JNICALL JNI(cancel)(JNIEnv *e, jobject s, jlong op) { (void)e; (void)s; return dansheng_cancel((uint64_t)op); }
JNIEXPORT jlong JNICALL JNI(close)(JNIEnv *e, jobject s, jlong engine) {
    (void)s; uint64_t op = 0; if (dansheng_close((uint64_t)engine, &op) != DANSHENG_OK) fail(e); return (jlong)op;
}
JNIEXPORT jbyteArray JNICALL JNI(platformPoll)(JNIEnv *e, jobject s, jlong engine) { (void)s; return poll_buffer(e, (uint64_t)engine, 1); }
JNIEXPORT jint JNICALL JNI(platformRespond)(JNIEnv *e, jobject s, jlong engine, jlong request, jbyteArray input) {
    (void)s; if (!input) return DANSHENG_INVALID_ARGUMENT;
    jsize len = (*e)->GetArrayLength(e, input); if (len > 8 * 1024 * 1024) return DANSHENG_LIMIT;
    jbyte *bytes = (*e)->GetByteArrayElements(e, input, NULL); if (!bytes) return DANSHENG_LIMIT;
    int32_t status = dansheng_platform_respond((uint64_t)engine, (uint64_t)request, (uint8_t *)bytes, (size_t)len);
    (*e)->ReleaseByteArrayElements(e, input, bytes, JNI_ABORT); return status;
}
