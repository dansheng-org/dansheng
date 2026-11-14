// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.android

/** UTF-8 byte arrays avoid JNI modified UTF-8. All native calls are nonblocking. */
object NativeCore {
    fun load() = System.loadLibrary("dansheng_android")
    external fun open(options: ByteArray): Long
    external fun request(engine: Long, request: ByteArray): Long
    external fun poll(operation: Long): ByteArray?
    external fun cancel(operation: Long): Int
    external fun close(engine: Long): Long
    external fun platformPoll(engine: Long): ByteArray?
    external fun platformRespond(engine: Long, request: Long, response: ByteArray): Int
}
