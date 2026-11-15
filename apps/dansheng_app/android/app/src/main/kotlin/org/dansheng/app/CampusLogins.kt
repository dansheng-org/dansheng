package org.dansheng.app

import android.os.SystemClock
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.dansheng.android.PortError
import org.json.JSONObject

/** Device-local, owner-only sign-in. Credentials never cross the Flutter/plugin/MCP boundary. */
internal class CampusLogins(private val rt: RuntimeHost) {
    private val serial = Mutex()
    private val recovered = mutableMapOf<Pair<String,String>,Long>()
    private val recentFailures = mutableMapOf<Pair<String,String>,Pair<Long,String>>()
    private val services=setOf("ecard","academic","power","bus","dining","forum","canvas","webvpn","cloud")
    // The cloud drive keeps its own password, so it is saved apart from the UIS one.
    private fun kind(service:String)=when { service in setOf("forum","canvas","cloud") -> service
        // Each WebDAV server keeps its own credentials.
        isWebdav(service) -> "webdav-"+service.removePrefix("webdav:"); else -> "uis" }
    private fun isWebdav(service:String)=service.matches(Regex("webdav:[0-9a-f]{12}"))
    private fun webdavIdsKey(account:String)="webdav-ids/$account"
    private val savedLogins = CampusLoginStore(
        { rt.vault.get(it) }, { k,v -> rt.vault.set(k,v) }, { rt.vault.delete(it) },
        { rt.prefs.getStringSet(webdavIdsKey(it),emptySet()).orEmpty().toSet() },
        { account,ids ->
            val edit=rt.prefs.edit()
            if(ids.isEmpty())edit.remove(webdavIdsKey(account)) else edit.putStringSet(webdavIdsKey(account),ids)
            check(edit.commit())
        },
    )
    private val forumConsent = ForumRiskConsent(
        readVersion = { account -> rt.prefs.getInt(ForumRiskConsent.key(account), 0) },
        writeVersion = { account, version ->
            val editor = rt.prefs.edit()
            if (version == null) editor.remove(ForumRiskConsent.key(account))
            else editor.putInt(ForumRiskConsent.key(account), version)
            if (!editor.commit()) throw PortError("StorageUnavailable")
        },
    )
    private fun suspendKey(account:String)="venue-password-suspended/$account"
    // The school locks an account after a few wrong passwords. Once a hidden login fails after the
    // saved password went out, nothing submits it automatically until a person or the school vouches
    // for a password again. Kept on disk: a restart must not buy another wrong attempt.
    internal fun venuePasswordSuspended(account:String)=rt.prefs.getBoolean(suspendKey(account),false)
    internal fun suspendVenuePassword(account:String){rt.prefs.edit().putBoolean(suspendKey(account),true).commit()}
    internal fun clearVenueSuspension(account:String){rt.prefs.edit().remove(suspendKey(account)).commit()}
    internal fun venueAccountActive(account:String)=rt.account()==account
    internal fun canRestoreVenue(account:String)=rt.account()==account && savedLogins.get(account,"uis")!=null && !venuePasswordSuspended(account)
    internal fun savedUisForVenue(account:String):String? {
        val epoch=rt.accountEpoch
        if(!canRestoreVenue(account))return null
        val secret=savedLogins.get(account,"uis")?.let { JSONObject(it).getString("secret") }
        return secret.takeIf { rt.account()==account && rt.accountEpoch==epoch }
    }
    private fun checkAccount(account:String, epoch:Long) {
        if(rt.account()!=account || epoch!=rt.accountEpoch) throw PortError("AccountChanged")
    }
    internal fun requireForumConsent(account:String) = synchronized(rt.authGuard) {
        if(rt.account()!=account)throw PortError("AccountChanged")
        forumConsent.requireAccepted(account)
    }
    // The caller holds the same lock as authenticate(). Explicit logout forgets the
    // saved secrets; switching accounts keeps each profile's credentials separate.
    fun accountChanged(previous:String?,forget:Boolean) {
        recovered.clear(); recentFailures.clear(); rt.visiblePage.clearSilentFailures()
        if(forget && previous!=null) {
            savedLogins.forgetAccount(previous)
            forumConsent.forget(previous)
            clearVenueSuspension(previous)
        }
    }
    /** Called under authGuard together with server removal; never targets the new account. */
    fun forgetWebdav(account:String,id:String,epoch:Long) = synchronized(rt.authGuard) {
        checkAccount(account,epoch)
        savedLogins.forgetWebdav(account,id)
        recovered.remove(account to "webdav:$id")
        recentFailures.remove(account to "webdav:$id")
    }
    private fun authenticate(service:String,account:String,email:String,secret:String):Any? {
        val p=JSONObject().put("account_id",account)
        return when(service){
            "ecard" -> rt.request("fudan.ecard.login",p.put("password",secret))
            // Postgraduate numbers (third digit 1 or 2) use the separate yjsxk course system.
            "academic" -> rt.request("fudan.academic.login",p.put("password",secret)
                .put("service",if(account.length>=3 && account[2] in "12") "postgraduate" else "undergraduate"))
            "power","bus","dining","webvpn" -> rt.request("fudan.life.login",p.put("service",service).put("password",secret))
            "canvas" -> rt.request("canvas.token.bind",p.put("token",secret.trim()).put("persist",false))
            "forum" -> rt.request("community.tea.login",p.put("email",email).put("password",secret))
            "cloud" -> rt.request("fudan.cloud.login",p.put("password",secret))
            else -> if(isWebdav(service))
                rt.request("webdav.login",p.put("id",service.removePrefix("webdav:")).put("username",email.trim()).put("password",secret))
                else throw PortError("MethodUnavailable")
        }
    }
    suspend fun connect(service:String,account:String,replace:Boolean=false,
        confirmForumRisk:(suspend ()->Unit)?=null,
        epoch:Long=rt.accountEpoch,
        prompt:(suspend (String)->Pair<String,String>)?=null):Any? = serial.withLock {
        if(service !in services && !isWebdav(service))throw PortError("MethodUnavailable")
        checkAccount(account,epoch)
        if(service=="forum")forumConsent.authorize(account,confirmForumRisk) { action ->
            synchronized(rt.authGuard) {
                checkAccount(account,epoch)
                action()
            }
        }
        val id=account to service
        val group=kind(service)
        val saved=synchronized(rt.authGuard) {
            checkAccount(account,epoch)
            val now=SystemClock.elapsedRealtime()
            if(!replace && prompt==null) {
                recentFailures[id]?.let { if(now-it.first<30_000)throw PortError(it.second) }
                if(recovered[id]?.let { now-it<8_000 }==true)return@withLock JSONObject().put("connected",true)
            }
            savedLogins.get(account,group)?.let(::JSONObject)
        }
        fun attempt(email:String, secret:String, save:Boolean):Any? = synchronized(rt.authGuard) {
            checkAccount(account,epoch)
            if(service=="forum")forumConsent.requireAccepted(account)
            val result=authenticate(service,account,email,secret)
            checkAccount(account,epoch)
            if(save)savedLogins.set(account,group,JSONObject().put("email",email).put("secret",secret).toString())
            // The school just accepted this UIS password; a forum or Canvas secret says nothing about it.
            if(kind(service)=="uis"){rt.visiblePage.clearSilentFailure(account);clearVenueSuspension(account)}
            recovered[id]=SystemClock.elapsedRealtime();recentFailures.remove(id)
            result
        }
        fun canvasViaCampus():Any? = synchronized(rt.authGuard) {
            checkAccount(account,epoch)
            if(venuePasswordSuspended(account))return@synchronized null
            val uis=savedLogins.get(account,"uis")?.let { JSONObject(it).getString("secret") } ?: return@synchronized null
            try {
                val result=rt.request("canvas.uis.login",JSONObject().put("account_id",account).put("password",uis))
                checkAccount(account,epoch); recovered[id]=SystemClock.elapsedRealtime();recentFailures.remove(id)
                clearVenueSuspension(account)
                result
            }catch(e:PortError){
                recentFailures[id]=SystemClock.elapsedRealtime() to e.code
                if(e.code=="InvalidCredentials")suspendVenuePassword(account)
                throw e
            }
        }
        // A suspended UIS password goes out again only when a person types it.
        if(!replace && saved!=null && !(kind(service)=="uis" && venuePasswordSuspended(account))) {
            try {return@withLock attempt(saved.optString("email"),saved.getString("secret"),false)}
            catch(e:PortError) {
                synchronized(rt.authGuard){
                    checkAccount(account,epoch)
                    recentFailures[id]=SystemClock.elapsedRealtime() to e.code
                    if(e.code=="InvalidCredentials" || ((service=="forum" || service=="canvas") && e.code=="AuthenticationRequired"))
                        savedLogins.delete(account,group)
                    else throw e
                }
                if(service!="canvas" && prompt==null)throw e
            }
        }
        if(service=="canvas" && !replace) {
            try {canvasViaCampus()?.let{return@withLock it}}
            catch(e:PortError){if(prompt==null || e.code !in setOf("AuthenticationRequired","InteractiveLoginRequired","InvalidCredentials"))throw e}
        }
        if(prompt==null)throw PortError("AuthenticationRequired")
        val (email,secret)=prompt(saved?.optString("email").orEmpty())
        if(secret.isEmpty())throw PortError("AuthenticationRequired")
        attempt(email.trim(),secret,true)
    }
    companion object {
        fun forumEmails(account:String):List<String> {
            if(!account.matches(Regex("[0-9]{2,}")))return emptyList()
            val modern=account.take(2).toInt()>=21
            return (if(modern) listOf("m.fudan.edu.cn","fudan.edu.cn") else listOf("fudan.edu.cn","m.fudan.edu.cn")).map { "$account@$it" }
        }
    }
}
