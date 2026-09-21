// Publishes a prebuilt AAR (assembled by ../assemble_aar.py) to GitHub Packages.
// No Android Gradle Plugin: the artifact is a file, the POM is written here.
//
//   ./gradlew publish -Pversion=1.6.0.0-1 -Paar=/path/to/x.aar [-Psources=/path/to/x-sources.jar] \
//       -PupstreamTag=v1.6.0.0 -PupstreamCommit=<sha>
//
// Credentials: gpr.user / gpr.token Gradle properties, else GITHUB_ACTOR / GITHUB_TOKEN
// (same order as asleep-ai/hue-ble-android).
plugins {
    `maven-publish`
}

fun prop(name: String, hint: String): String =
    (project.findProperty(name) as String?)?.takeIf { it != "unspecified" && it.isNotBlank() }
        ?: "MISSING-$name".also { missing += "-P$name=$hint" }

val missing = mutableListOf<String>()
val publishVersion = prop("version", "<upstream version>-<build>, e.g. 1.6.0.0-1")
val aarPath = prop("aar", "<path to .aar>")
val upstreamTag = prop("upstreamTag", "v<upstream tag>")
val upstreamCommit = prop("upstreamCommit", "<sha>")
val sourcesPath = (project.findProperty("sources") as String?)?.takeIf { it.isNotBlank() }
val upstreamRepo = "https://github.com/project-chip/connectedhomeip"
val thisRepo = "https://github.com/asleep-ai/android-prebuilts"

// Compile-scope dependencies the jars need but do not carry:
//  - androidx.annotation: the one entry of upstream third_party/android_deps/android_deps.gradle
//  - kotlin-stdlib: OnboardingPayload/libMatterTlv/libMatterJson/CHIPClusters are Kotlin
//    (kotlinc 2.1.10 in chip-build-android:200); consumers on newer Kotlin resolve upward.
val runtimeDeps = listOf(
    "androidx.annotation" to ("annotation" to "1.1.0"),
    "org.jetbrains.kotlin" to ("kotlin-stdlib" to "2.1.10"),
)

tasks.withType<PublishToMavenRepository>().configureEach {
    doFirst {
        require(missing.isEmpty()) { "missing properties: ${missing.joinToString(" ")}" }
        require(file(aarPath).isFile) { "AAR not found: $aarPath" }
        sourcesPath?.let { require(file(it).isFile) { "sources jar not found: $it" } }
    }
}

publishing {
    publications {
        create<MavenPublication>("gpr") {
            groupId = "ai.asleep"
            artifactId = "matter-sdk-android"
            version = publishVersion
            artifact(file(aarPath)) {
                extension = "aar"
            }
            sourcesPath?.let {
                artifact(file(it)) {
                    classifier = "sources"
                    extension = "jar"
                }
            }
            pom {
                packaging = "aar"
                name.set("Matter SDK for Android (connectedhomeip controller prebuilt)")
                description.set(
                    "Android controller library of project-chip/connectedhomeip $upstreamTag " +
                        "($upstreamCommit), arm64-v8a release build. Java classes chip.devicecontroller.*, " +
                        "chip.platform.*, matter.onboardingpayload.* plus libCHIPController.so and libc++_shared.so."
                )
                url.set("$upstreamRepo/tree/$upstreamTag")
                licenses {
                    license {
                        name.set("Apache-2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0")
                    }
                }
                scm {
                    url.set("$upstreamRepo/tree/$upstreamTag")
                    connection.set("scm:git:$upstreamRepo.git")
                    tag.set(upstreamTag)
                }
                properties.set(
                    mapOf(
                        "upstream.tag" to upstreamTag,
                        "upstream.commit" to upstreamCommit,
                        "prebuilt.recipe" to "$thisRepo/tree/connectedhomeip-v$publishVersion/connectedhomeip",
                    )
                )
                withXml {
                    val deps = asNode().appendNode("dependencies")
                    runtimeDeps.forEach { (group, artifactAndVersion) ->
                        val dep = deps.appendNode("dependency")
                        dep.appendNode("groupId", group)
                        dep.appendNode("artifactId", artifactAndVersion.first)
                        dep.appendNode("version", artifactAndVersion.second)
                        dep.appendNode("scope", "compile")
                    }
                }
            }
        }
    }
    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/asleep-ai/android-prebuilts")
            credentials {
                username = (project.findProperty("gpr.user") as String?)
                    ?: System.getenv("GITHUB_ACTOR")
                    ?: ""
                password = (project.findProperty("gpr.token") as String?)
                    ?: System.getenv("GITHUB_TOKEN")
                    ?: ""
            }
        }
    }
}
