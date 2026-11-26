plugins {
    alias(libs.plugins.android.application) apply false
    // AGP 9 has Kotlin built in; declaring the plugin here pins its version to what connect-kotlin was built with
    alias(libs.plugins.kotlin.android) apply false
}
