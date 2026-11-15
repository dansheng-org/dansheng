package org.dansheng.app

/** Device credential persistence, including the index used by explicit logout. */
internal class CampusLoginStore(
    private val read:(String)->String?,
    private val write:(String,String)->Unit,
    private val erase:(String)->Unit,
    private val ids:(String)->Set<String>,
    private val saveIds:(String,Set<String>)->Unit,
) {
    private fun key(account:String,group:String)="campus-login/v1/$group/$account"
    fun get(account:String,group:String)=read(key(account,group))
    fun delete(account:String,group:String)=erase(key(account,group))
    fun set(account:String,group:String,value:String) {
        write(key(account,group),value)
        if(group.startsWith("webdav-"))saveIds(account,ids(account)+group.removePrefix("webdav-"))
    }
    fun forgetWebdav(account:String,id:String) {
        delete(account,"webdav-$id")
        saveIds(account,ids(account)-id)
    }
    fun forgetAccount(account:String) {
        for(group in listOf("uis","forum","canvas","cloud"))delete(account,group)
        for(id in ids(account))delete(account,"webdav-$id")
        saveIds(account,emptySet())
    }
}
