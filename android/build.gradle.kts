// 本机可用工具链：Gradle 9.3.1 + AGP 9.1.0 + JDK 17+
// 注意：AGP 9.0 起「内置 Kotlin 支持」，不能再单独 apply org.jetbrains.kotlin.android，
//      否则会直接报 "The 'org.jetbrains.kotlin.android' plugin is no longer required"。
plugins {
    id("com.android.application") version "9.1.0" apply false
}
