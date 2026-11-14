plugins { id("com.android.application") }
android {
    namespace = "org.dansheng.verification"
    compileSdk = 37
    useLibrary("android.test.runner")
    useLibrary("android.test.base")
    if (project.hasProperty("rustJniDir")) sourceSets["androidTest"].kotlin.directories += "src/nativeTest/java"
    defaultConfig {
        applicationId = "org.dansheng.verification"
        minSdk = 28; targetSdk = 37
        versionCode = 1; versionName = "0.1"
        testInstrumentationRunner = "org.dansheng.verification.VerificationRunner"
    }
}
dependencies { implementation(project(":adapter")) }

val stageSportsFixturePlugin = tasks.register<Sync>("stageSportsFixturePlugin") {
    from("../../../plugins/fudan-sports") {
        include("manifest.json", "api.mjs", "main.mjs", "policy.mjs", "platform-support.json", "NOTICE.md", "types.d.ts")
    }
    into(layout.buildDirectory.dir("generated/sports-assets/fudan-sports"))
}
tasks.named("preBuild") { dependsOn(stageSportsFixturePlugin) }
val stageClosedLoopFixturePlugin = tasks.register<Copy>("stageClosedLoopFixturePlugin") {
    from("../../../plugins/fixtures/closed-loop") { include("manifest.json", "main.mjs", "LICENSE", "README.md") }
    into(layout.buildDirectory.dir("generated/sports-assets/closed-loop"))
}
tasks.named("preBuild") { dependsOn(stageClosedLoopFixturePlugin) }
androidComponents {
    onVariants(selector().all()) { variant ->
        variant.sources.assets?.addStaticSourceDirectory(layout.buildDirectory.dir("generated/sports-assets").get().asFile.absolutePath)
    }
}
