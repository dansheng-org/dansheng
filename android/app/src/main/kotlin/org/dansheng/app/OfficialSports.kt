package org.dansheng.app

/** Only these released archives can reuse the owner's saved venue sign-in. */
internal object OfficialSports {
    const val id="official.fudan-sports"
    private val releases=mapOf(
        "0.1.0" to "62c0595049cac7f7a1e3c25ccbddcc170c861012782ff8e19418bd8a7abce7e1",
        "0.2.0" to "408e8470be95afa8c22755cea94bb829909d83a59087a1ea5d317b91ed7a09ea",
    )
    fun recognized(id:String, version:String, digest:String)=id==this.id && releases[version]?.equals(digest,true)==true
}
