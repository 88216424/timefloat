plugins {
    // AGP 9 自带 Kotlin 编译支持，Kotlin 源码放在 src/main/java 或 src/main/kotlin 都会被编译
    id("com.android.application")
}

android {
    namespace = "com.yesha.timefloat"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.yesha.timefloat"
        minSdk = 24
        targetSdk = 36
        versionCode = 2
        versionName = "1.1"
    }

    buildTypes {
        release {
            // 自用：不开混淆，省得排查问题麻烦
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // 直接用 debug 密钥签名，方便 adb install 直接装
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += setOf("META-INF/*.kotlin_module")
    }
}

// 零第三方依赖：网络用 HttpURLConnection / DatagramSocket，JSON 用系统自带的 org.json
dependencies {
}
