import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

/** Build timestamp (San Francisco / PT), stamped at configuration time. */
val buildTimestamp: String = DateTimeFormatter
    .ofPattern("yyyy-MM-dd HH:mm:ss z")
    .withZone(ZoneId.of("America/Los_Angeles"))
    .format(Instant.now())

/** Short git SHA of the working tree, best-effort (falls back to "unknown"). */
val gitSha: String = runCatching {
    val proc = ProcessBuilder("git", "rev-parse", "--short", "HEAD")
        .directory(rootDir)
        .redirectErrorStream(true)
        .start()
    proc.inputStream.bufferedReader().readText().trim().ifEmpty { "unknown" }
}.getOrDefault("unknown")

// ── Versioning: read from version.properties (see that file for how to bump) ──
// Falls back to safe debug-friendly defaults so a fresh checkout without the
// file (or with a malformed one) still builds.
val versionProps = Properties().apply {
    val propsFile = rootProject.file("version.properties")
    if (propsFile.exists()) {
        propsFile.inputStream().use { load(it) }
    }
}
val appVersionCode: Int = versionProps.getProperty("VERSION_CODE")?.toIntOrNull() ?: 1
val appVersionName: String = versionProps.getProperty("VERSION_NAME") ?: "0.0.1-dev"

// ── Release signing: keystore.properties (local, gitignored) OR env vars (CI) ──
// Local dev: copy apps/android/keystore.properties.example to
// apps/android/keystore.properties and fill in real values (never commit it).
// CI: set CRUMB_RELEASE_KEYSTORE_PATH / _PASSWORD / _KEY_ALIAS / _KEY_PASSWORD
// env vars instead (see .github/workflows/android-release.yml).
//
// If NEITHER is present, release signing config is simply not configured —
// `assembleDebug` and normal local dev are completely unaffected. Only
// `assembleRelease` / `bundleRelease` need this, and Gradle will fail those
// tasks with a clear "no signing config" error rather than silently producing
// an unsigned artifact.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}

fun releaseSigningValue(propKey: String, envVar: String): String? =
    keystoreProps.getProperty(propKey) ?: System.getenv(envVar)

val releaseStoreFilePath = releaseSigningValue("storeFile", "CRUMB_RELEASE_KEYSTORE_PATH")
val releaseStorePassword = releaseSigningValue("storePassword", "CRUMB_RELEASE_KEYSTORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("keyAlias", "CRUMB_RELEASE_KEY_ALIAS")
val releaseKeyPassword = releaseSigningValue("keyPassword", "CRUMB_RELEASE_KEY_PASSWORD")

// Resolve storeFile relative to this module (app/) if it's a relative path,
// same convention keystore.properties.example documents.
val releaseStoreFile = releaseStoreFilePath?.let { path ->
    file(path).let { f -> if (f.isAbsolute) f else rootProject.file(path) }
}

val hasReleaseSigningConfig: Boolean =
    releaseStoreFile != null && releaseStoreFile.exists() &&
        releaseStorePassword != null && releaseKeyAlias != null && releaseKeyPassword != null

android {
    namespace = "video.crumb.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "video.crumb.app"
        minSdk = 26
        targetSdk = 34
        versionCode = appVersionCode
        versionName = appVersionName

        // Default server URL — overridable at runtime in the login screen.
        // Points at the LAN-exposed API; over Tailscale the user supplies their own.
        buildConfigField("String", "DEFAULT_SERVER_URL", "\"http://192.0.2.10:8080\"")

        // Build metadata for the in-app About panel (debugging which build is installed).
        buildConfigField("String", "BUILD_TIME", "\"$buildTimestamp\"")
        buildConfigField("String", "GIT_SHA", "\"$gitSha\"")
    }

    // Only declared when we actually have something to sign with — an absent
    // keystore.properties/env vars must never break debug builds or plain
    // `./gradlew build` for local dev.
    if (hasReleaseSigningConfig) {
        signingConfigs {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            // R8 shrink + obfuscate + resource shrink. Keep rules for our
            // reflectively-accessed code live in proguard-rules.pro; libraries ship
            // their own consumer rules. Debug builds keep minify off for fast iteration.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (hasReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
            // If no signing config is available, `assembleRelease` still runs
            // (useful for size/lint checks) but produces an unsigned APK — Gradle
            // will just fall back to no signingConfig rather than failing here.
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    debugImplementation(libs.androidx.ui.tooling)

    // Video — Media3 / ExoPlayer with hardware decode (MediaCodec).
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.exoplayer.rtsp)
    implementation(libs.androidx.media3.exoplayer.hls)
    implementation(libs.androidx.media3.ui)

    // Networking.
    implementation(libs.retrofit)
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.retrofit.kotlinx.serialization)

    // Secure token storage + image loading (filmstrip thumbnails).
    implementation(libs.androidx.security.crypto)
    implementation(libs.coil.compose)

    // Biometric / device-credential app lock (BiometricPrompt). Pulls androidx.fragment,
    // which is why MainActivity is a FragmentActivity.
    implementation(libs.androidx.biometric)
}
