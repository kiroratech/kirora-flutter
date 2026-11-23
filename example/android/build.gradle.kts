allprojects {
    repositories {
        // KIRORA_ANDROID_LOCAL=1: build against a local publish of the Android SDK
        // (`./gradlew publishToMavenLocal` there), ahead of the released one.
        if (System.getenv("KIRORA_ANDROID_LOCAL") != null) {
            mavenLocal { content { includeGroup("io.kirora") } }
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
