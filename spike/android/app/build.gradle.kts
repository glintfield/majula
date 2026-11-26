plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "dev.majula.spike"
    // okhttp-android 5.5 requires compiling against 37; targetSdk stays on the installed 35 image
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.majula.spike"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "0.0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.connect.kotlin)
    implementation(libs.connect.kotlin.okhttp)
    implementation(libs.connect.kotlin.javalite)
    implementation(libs.okhttp)
    implementation(libs.okhttp.tls)
    implementation(libs.protobuf.javalite)
    implementation(libs.coroutines.android)
    implementation(libs.androidx.activity)
    implementation(libs.androidx.lifecycle.runtime)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.uiautomator)
}
