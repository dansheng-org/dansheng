package org.dansheng.app

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Locale
import java.util.zip.ZipFile

/** Local, explicitly selected packages use Core's untrusted local installer, never publisher trust. */
internal object PackageImport {
    private const val LIMIT = 16 * 1024 * 1024
    private val name = Regex("[A-Za-z0-9_][A-Za-z0-9._-]{0,127}")
    fun stage(context: Context, uri: Uri): File {
        require(uri.scheme == "content") { "InvalidDocument" }
        val input=context.contentResolver.openInputStream(uri) ?: error("DocumentUnreadable")
        return input.use { stage(context,it) }
    }
    fun stage(context:Context, input:InputStream):File {
        val dir = Files.createTempDirectory(context.cacheDir.toPath(), "import-").toFile()
        try {
            val zip = File(dir, "download.zip")
            copyBounded(input, zip, LIMIT)
            val pkg = File(dir, "package").apply { check(mkdir()) }
            ZipFile(zip).use { archive ->
                val names = mutableSetOf<String>()
                var remaining = LIMIT
                val entries = archive.entries()
                while (entries.hasMoreElements()) {
                    val item = entries.nextElement()
                    require(!item.isDirectory && name.matches(item.name) && !item.name.endsWith(".") &&
                        names.size < 256 && names.add(item.name.lowercase(Locale.ROOT))) { "InvalidPackage" }
                    remaining -= archive.getInputStream(item).use { copyBounded(it, File(pkg, item.name), remaining) }
                }
            }
            val manifest = File(pkg, "manifest.json")
            require(manifest.isFile && manifest.length() <= 256 * 1024) { "InvalidManifest" }
            JSONObject(manifest.readText()).getString("id")
            return dir
        } catch (e: Exception) { dir.deleteRecursively(); throw e }
    }
    private fun copyBounded(input: InputStream, dest: File, limit: Int): Int {
        var count = 0
        val buffer = ByteArray(8192)
        dest.outputStream().use { out ->
            while (true) {
                val n = input.read(buffer); if (n < 0) break
                require(n <= limit - count) { "PackageTooLarge" }; count += n
                out.write(buffer, 0, n)
            }
        }
        return count
    }
    fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val b = ByteArray(8192)
            while (true) { val n = stream.read(b); if (n < 0) break; hash.update(b, 0, n) }
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
}
