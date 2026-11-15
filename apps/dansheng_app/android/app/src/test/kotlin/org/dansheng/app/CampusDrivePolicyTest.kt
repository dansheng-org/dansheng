package org.dansheng.app

import org.dansheng.android.PortError
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class CampusDrivePolicyTest {
    @Test fun acceptedLocalFileFitsTheActualJsonEnvelope() {
        CampusUploadPolicy.checkLocalSize(CampusUploadPolicy.LOCAL_MAX_BYTES.toLong())
        val data=Base64.getEncoder().encodeToString(ByteArray(CampusUploadPolicy.LOCAL_MAX_BYTES))
        val request=JSONObject().put("id","upload").put("method","fudan.cloud.upload")
            .put("params",JSONObject().put("data_base64",data).put("account_id","account")
                .put("path","3/42/directory/"+"资料".repeat(1024)).put("name","课".repeat(200)))
        assertTrue(request.toString().toByteArray(Charsets.UTF_8).size<8*1024*1024)
        try {
            CampusUploadPolicy.checkLocalSize(CampusUploadPolicy.LOCAL_MAX_BYTES+1L)
            fail("oversized local file accepted")
        } catch(e:PortError) { assertEquals("LocalUploadTooLarge",e.code) }
    }

    @Test fun removalForgetsOnlyThatServersPasswordAndLogoutStillForgetsTheRest() {
        val vault=mutableMapOf<String,String>()
        val index=mutableMapOf<String,Set<String>>()
        val store=CampusLoginStore({vault[it]}, {k,v->vault[k]=v}, {vault.remove(it)},
            {index[it].orEmpty()}, {account,ids->index[account]=ids})
        val id="abcdef012345"
        store.set("A","webdav-$id","A password")
        store.set("B","webdav-$id","B password")
        store.set("A","webdav-111111111111","other server")
        store.set("A","uis","UIS password")
        store.forgetWebdav("A",id)
        // Re-adding the same deterministic server id must not restore its old password.
        assertNull(store.get("A","webdav-$id"))
        assertEquals("B password",store.get("B","webdav-$id"))
        assertEquals("other server",store.get("A","webdav-111111111111"))
        assertFalse(index["A"]!!.contains(id))
        store.forgetAccount("A")
        assertNull(store.get("A","uis"))
        assertNull(store.get("A","webdav-111111111111"))
        assertEquals("B password",store.get("B","webdav-$id"))
    }
}
