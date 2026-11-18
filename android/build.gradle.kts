group = "io.kirora.flutter"
version = "0.1.0"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        // Development: the Kirora Android SDK is published here by `./gradlew publishToMavenLocal`.
        mavenLocal()
    }
}

plugins {
    id("com.android.library")
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

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    val kiroraSdkVersion = (findProperty("kiroraAndroidSdkVersion") as String?) ?: "0.1.0"
    // The core SDK, and the Firebase side of push (FCM service, notification permission).
    api("com.kirora:android-sdk:$kiroraSdkVersion")
    implementation("com.kirora:android-sdk-push:$kiroraSdkVersion")

    // Unverified: see KiroraFlutterPluginTest. Needs a Flutter build that supplies the embedding.
    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("org.mockito:mockito-core:5.14.2")
}
