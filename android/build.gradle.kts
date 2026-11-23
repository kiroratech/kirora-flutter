group = "io.kirora.flutter"
version = "0.1.0"

buildscript {
    val kotlinVersion = "2.1.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.9.3")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// AGP 9 compiles Kotlin itself (built-in Kotlin) unless the host sets `android.builtInKotlin=false`.
// Otherwise (and always on AGP 8) the Kotlin Android plugin is needed, which older Flutter
// versions don't apply to plugins on their own.
val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val builtInKotlin = agpMajor >= 9 &&
    (findProperty("android.builtInKotlin")?.toString()?.toBoolean() ?: true)
if (!builtInKotlin) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "io.kirora.flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }
}

// Not the `kotlin {}` block: its accessor only exists when the Kotlin plugin is applied in
// `plugins {}`, which AGP 9 forbids and AGP 8 needs.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
}

dependencies {
    val kiroraSdkVersion = (findProperty("kiroraAndroidSdkVersion") as String?) ?: "0.1.0"
    // The core SDK, and the Firebase side of push (FCM service, notification permission). Both are
    // `api` so a host's own FirebaseMessagingService can forward to KiroraPush. An app without push
    // sets `kiroraPush=false` in its gradle.properties: no Firebase, no notification permission.
    // The core SDK runs without it, and the push calls answer `unsupported`.
    api("com.kirora:android-sdk:$kiroraSdkVersion")
    if ((findProperty("kiroraPush") as String?)?.toBoolean() != false) {
        api("com.kirora:android-sdk-push:$kiroraSdkVersion")
    }

    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("org.mockito:mockito-core:5.14.2")
}
