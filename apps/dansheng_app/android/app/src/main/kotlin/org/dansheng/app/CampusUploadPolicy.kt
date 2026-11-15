package org.dansheng.app

import org.dansheng.android.PortError

internal object CampusUploadPolicy {
    // Base64 of 5 MiB is < 7 MiB, leaving > 1 MiB for the 8 MiB FFI JSON envelope.
    const val LOCAL_MAX_BYTES = 5 * 1024 * 1024
    fun checkLocalSize(bytes:Long) {
        if(bytes>LOCAL_MAX_BYTES)throw PortError("LocalUploadTooLarge")
    }
}
