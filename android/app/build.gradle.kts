plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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
    sourceSets["androidTest"].assets.srcDir(rootProject.file("../../dansheng/plugins/fixtures"))
    sourceSets["main"].assets.srcDir(rootProject.file("../.local/native/legal"))
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
    implementation(files(rootProject.file("../.local/native/dansheng-android-0.1.0.aar")))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20180813")
}

val stageVenueService by tasks.registering(Sync::class) {
    into(layout.buildDirectory.dir("official-campus-assets"))
    into("builtin-venues") {
        from(rootProject.file("../../dansheng/plugins/builtin/fudan-venues")) {
            include("manifest.json","host-policy.json","main.mjs","api.mjs","policy.mjs","NOTICE.md")
        }
        from(rootProject.file("../../dansheng/LICENSE"))
    }
}
tasks.named("preBuild"){ dependsOn(stageVenueService) }

val stageExternalTestPlugin by tasks.registering(Sync::class) {
    from(rootProject.file("../dist")) { include("official.fudan-sports-0.2.0.dspack") }
    into(layout.buildDirectory.dir("qa-plugins"))
}
tasks.matching { it.name == "mergeDebugAndroidTestAssets" }.configureEach {
    dependsOn(stageExternalTestPlugin)
}
