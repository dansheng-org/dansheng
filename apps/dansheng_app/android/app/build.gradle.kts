import groovy.json.JsonSlurper
import java.io.File
import java.io.InputStream
import java.net.URI
import java.security.MessageDigest
import java.util.Collections
import java.util.zip.ZipFile

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Explicit Core/SDK selection wins; paired tasks and the renamed sibling work offline.
val danshengAppRoot = rootProject.projectDir.parentFile
fun appPath(value: String): File = File(value).let {
    (if (it.isAbsolute) it else File(danshengAppRoot, value)).canonicalFile
}
val danshengDefaultCoreCandidates = buildList {
    if (danshengAppRoot.name.equals("dansheng_app", ignoreCase = true) &&
        danshengAppRoot.parentFile.name.equals("apps", ignoreCase = true)) {
        add(File(danshengAppRoot.parentFile.parentFile, "core"))
    }
    if (danshengAppRoot.name.equals("app", ignoreCase = true)) add(File(danshengAppRoot.parentFile, "core"))
    add(File(danshengAppRoot.parentFile, "dansheng-core"))
    add(File(danshengAppRoot.parentFile, "dansheng"))
}
val danshengDefaultCore = danshengDefaultCoreCandidates.firstOrNull {
    File(it, "Cargo.toml").isFile && File(it, "include/dansheng.h").isFile
} ?: File(danshengAppRoot.parentFile, "dansheng-core")
val danshengCoreRoot = appPath(providers.gradleProperty("danshengCoreRoot")
    .orElse(providers.environmentVariable("DANSHENG_CORE_ROOT"))
    .getOrElse(danshengDefaultCore.path))
val danshengSdkRoot = appPath(providers.gradleProperty("danshengCoreSdkDir")
    .orElse(providers.environmentVariable("DANSHENG_CORE_SDK_DIR"))
    .getOrElse(File(danshengAppRoot, ".local/native").path))
val danshengLockFile = appPath(providers.gradleProperty("danshengCoreLockFile")
    .orElse(providers.environmentVariable("DANSHENG_CORE_LOCK_FILE"))
    .getOrElse("core.lock.json"))
val danshengArtifactRoot = appPath(providers.gradleProperty("danshengAppArtifactDir")
    .orElse(providers.environmentVariable("DANSHENG_ARTIFACT_DIR"))
    .orElse(providers.environmentVariable("DANSHENG_TASK_RUNTIME").map { File(it, "artifacts").path })
    .getOrElse(File(danshengAppRoot, "dist").path))
val danshengLock = if (danshengLockFile.isFile) {
    JsonSlurper().parse(danshengLockFile) as? Map<*, *>
        ?: error("Invalid Core dependency lock")
} else null
val danshengArtifact = danshengLock?.get("artifact") as? Map<*, *>
val danshengAarName = (danshengArtifact?.get("name") as? String)
    ?: "dansheng-android-0.1.0.aar"
require(danshengAarName.isNotBlank() && danshengAarName !in setOf(".", "..") &&
    !danshengAarName.contains('/') && !danshengAarName.contains('\\')) { "Unsafe Core AAR name" }
val danshengAar = File(danshengSdkRoot, danshengAarName)
val danshengResources = if (File(danshengCoreRoot, "Cargo.toml").isFile) {
    danshengCoreRoot
} else File(danshengSdkRoot, "resources")
fun streamSha(input: InputStream): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(8192)
    while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
    return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
}
fun sourceSha(file: File): String = file.inputStream().use { streamSha(it) }
val verifyDanshengCoreDependency by tasks.registering {
    doLast {
        require(danshengAar.isFile) { "Prepare the exact Core native SDK before an Android build" }
        if (danshengLock != null) {
            val artifact = danshengArtifact ?: error("Core artifact identity missing")
            require(danshengLock["format"] == "dansheng-core-lock-v1" && danshengLock["mode"] == "native-sdk") { "Unsupported Core lock" }
            require(artifact["format"] == "aar" && artifact["platform"] == "android") { "Unsupported Core artifact platform" }
            val abis = artifact["abis"] as? List<*> ?: error("Core ABI identities missing")
            require(abis.size == 2 && abis.toSet() == setOf("arm64-v8a", "x86_64")) { "Core SDK must lock both supported Android ABIs" }
            val core = danshengLock["core"] as? Map<*, *> ?: error("Core identity missing")
            val hashPattern = Regex("[a-fA-F0-9]{64}")
            require((core["api_version"] as? Number)?.toDouble() == 1.0 &&
                (core["abi_version"] as? Number)?.toDouble() == 1.0 &&
                (core["source_sha256"] as? String)?.matches(hashPattern) == true &&
                (core["adapter_source_sha256"] as? String)?.matches(hashPattern) == true) { "Core protocol/source identities differ" }
            require(sourceSha(danshengAar).equals(danshengArtifact?.get("sha256") as? String, ignoreCase = true) &&
                danshengAar.length() == (danshengArtifact?.get("bytes") as? Number)?.toLong()) { "Core AAR differs from lock" }
            val binding = danshengLock["binding"] as? Map<*, *> ?: error("Core binding identity missing")
            val pubLock = File(danshengAppRoot, "pubspec.lock")
            val pigeonVersion = Regex("""(?ms)^  pigeon:\r?\n(?:(?!^  [a-zA-Z_]).)*?version:\s*"([^"]+)"""")
                .find(pubLock.readText())?.groupValues?.get(1)
            require(binding["kind"] == "pigeon-jni" && pigeonVersion != null &&
                binding["generator_version"] == pigeonVersion) { "Core binding/Pigeon identity differs" }
            require(sourceSha(File(danshengAppRoot, "pubspec.lock")).equals(binding?.get("pubspec_lock_sha256") as? String, ignoreCase = true)) { "Pub/Pigeon lock differs" }
            val natives = artifact["native_entries"] as? List<*> ?: error("Core native entries missing")
            val requiredNatives = setOf("jni/arm64-v8a/libdansheng_ffi.so", "jni/x86_64/libdansheng_ffi.so")
            require(natives.size == 2 && natives.map { (it as? Map<*, *>)?.get("entry") }.toSet() == requiredNatives) { "Core native entry lock is incomplete or duplicated" }
            ZipFile(danshengAar).use { archive ->
                for (item in natives) {
                    val native = item as? Map<*, *> ?: error("Invalid Core native lock")
                    val name = native["entry"] as? String ?: error("Native name missing")
                    require(Collections.list(archive.entries()).count { it.name == name } == 1) { "Core native payload is missing or duplicated" }
                    val entry = archive.getEntry(name) ?: error("Core native payload missing")
                    require(entry.size in 1..(512L * 1024 * 1024) && entry.size == (native["bytes"] as? Number)?.toLong() &&
                        archive.getInputStream(entry).use { streamSha(it) }.equals(native["sha256"] as? String, ignoreCase = true)) { "Core native payload differs from lock" }
                }
            }
            val resources = danshengLock["resources"] as? List<*> ?: error("Core resource hashes missing")
            val requiredResources = setOf("plugins/builtin/fudan-venues/manifest.json", "plugins/builtin/fudan-venues/host-policy.json",
                "plugins/builtin/fudan-venues/main.mjs", "plugins/builtin/fudan-venues/api.mjs", "plugins/builtin/fudan-venues/policy.mjs",
                "plugins/builtin/fudan-venues/NOTICE.md", "LICENSE")
            require(resources.size == requiredResources.size &&
                resources.map { (it as? Map<*, *>)?.get("path") }.toSet() == requiredResources) { "Core runtime resource lock is incomplete or duplicated" }
            for (entry in resources) {
                val resource = entry as? Map<*, *> ?: error("Invalid Core resource lock")
                val name = resource["path"] as? String ?: error("Resource path missing")
                require(!File(name).isAbsolute && name.split('/', '\\').none { it == ".." }) { "Unsafe resource path" }
                val file = File(danshengResources, name).canonicalFile
                require(file.toPath().startsWith(danshengResources.canonicalFile.toPath()) && file.isFile &&
                    sourceSha(file).equals(resource["sha256"] as? String, ignoreCase = true)) { "Core runtime resource differs from lock" }
            }
            if (providers.gradleProperty("danshengStableRelease").orNull == "true") {
                val commit = core["commit"] as? String ?: ""
                require(danshengLock["state"] == "release" && danshengArtifact?.get("packaged_receipt_complete") == true &&
                    commit.matches(Regex("(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})"))) { "Development snapshot or incomplete packaged receipt is not a stable dependency" }
                val uri = URI(danshengArtifact?.get("acquisition_uri") as? String ?: "")
                require(uri.isAbsolute && uri.scheme == "https" && uri.userInfo == null && uri.query == null && uri.fragment == null) { "Stable SDK needs a credential-free published acquisition" }
                require(!File(danshengAppRoot, "pubspec_overrides.yaml").exists()) { "Local Pub override is active" }
            }
        } else require(providers.gradleProperty("danshengStableRelease").orNull != "true") { "Stable build requires core.lock.json" }
    }
}
tasks.named("preBuild") { dependsOn(verifyDanshengCoreDependency) }

android {
    namespace = "org.dansheng.app"
    compileSdk = 37
    ndkVersion = "30.0.16138531"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.dansheng.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 37
        testInstrumentationRunner = if (providers.gradleProperty("campusReadOnly").orNull=="true")
            "org.dansheng.app.checks.CampusReadOnlyRunner" else "org.dansheng.app.checks.ProductRunner"
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    // Test APK only; the product APK never packages fixture or sports code.
    sourceSets["androidTest"].assets.srcDir(File(danshengCoreRoot, "plugins/fixtures"))
    sourceSets["main"].assets.srcDir(File(danshengSdkRoot, "legal"))
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("official-campus-assets").get().asFile)
    sourceSets["androidTest"].assets.srcDir(layout.buildDirectory.dir("qa-plugins").get().asFile)

    val betaKey = providers.environmentVariable("DANSHENG_BETA_STORE")
    if (betaKey.isPresent) signingConfigs.create("internalBeta") {
        storeFile = file(betaKey.get())
        storePassword = providers.environmentVariable("DANSHENG_BETA_PASSWORD").get()
        keyAlias = "dansheng-beta"
        keyPassword = storePassword
    }
    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.findByName("internalBeta")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.material:material:1.14.0")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation(files(danshengAar))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20180813")
}

val stageVenueService by tasks.registering(Sync::class) {
    into(layout.buildDirectory.dir("official-campus-assets"))
    into("builtin-venues") {
        from(File(danshengResources, "plugins/builtin/fudan-venues")) {
            include("manifest.json","host-policy.json","main.mjs","api.mjs","policy.mjs","NOTICE.md")
        }
        from(File(danshengResources, "LICENSE"))
    }
}
tasks.named("preBuild"){ dependsOn(stageVenueService) }

val stageExternalTestPlugin by tasks.registering(Sync::class) {
    from(danshengArtifactRoot) { include("official.fudan-sports-0.2.0.dspack") }
    into(layout.buildDirectory.dir("qa-plugins"))
}
tasks.matching { it.name == "mergeDebugAndroidTestAssets" }.configureEach {
    dependsOn(stageExternalTestPlugin)
}
