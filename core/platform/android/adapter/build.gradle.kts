plugins { id("com.android.library") }
android {
    namespace = "org.dansheng.android"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
        ndk { abiFilters += (project.findProperty("androidAbis")?.toString()?.split(',') ?: listOf("arm64-v8a", "x86_64")) }
        if (project.hasProperty("rustJniDir")) {
            externalNativeBuild { cmake { arguments += "-DDANSHENG_RUST_JNI_DIR=${project.property("rustJniDir")}" } }
        }
    }
    ndkVersion = "30.0.16138531"
    if (project.hasProperty("rustJniDir")) {
        externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
        packaging.jniLibs.pickFirsts += "**/libdansheng_ffi.so"
    }
    testOptions { unitTests.isReturnDefaultValues = true }
}
androidComponents {
    onVariants(selector().all()) { variant ->
        if (project.hasProperty("rustJniDir")) {
            variant.sources.jniLibs?.addStaticSourceDirectory(project.property("rustJniDir").toString())
        }
    }
}
dependencies { testImplementation("junit:junit:4.13.2") }
