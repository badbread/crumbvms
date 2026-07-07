# ─── CrumbVMS — R8 / ProGuard keep rules ─────────────────────────────────────
# Release builds run R8 (full mode) with shrink + obfuscation. Most libraries we
# use (Retrofit, OkHttp, Coil, Media3) ship their own consumer rules in their AARs,
# so the rules here focus on what R8 can't infer: our own reflectively-accessed
# code (kotlinx.serialization models, Retrofit service interfaces).

-keepattributes *Annotation*, InnerClasses, Signature, Exceptions, EnclosingMethod

# ── kotlinx.serialization ─────────────────────────────────────────────────────
# Keep the synthetic serializer + Companion of every @Serializable type so the
# reflective `serializer()` lookup resolves after obfuscation.
-dontnote kotlinx.serialization.**

-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$Companion Companion;
}
-if @kotlinx.serialization.Serializable class ** {
    static **$Companion Companion;
}
-keepclassmembers class <2>$Companion {
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclasseswithmembers class **$$serializer { *; }

# Our DTOs/models all carry @Serializable — keep them and their members outright
# (they're the payload contract with the API; obfuscating fields breaks JSON).
-keep @kotlinx.serialization.Serializable class video.crumb.app.data.** { *; }

# ── Retrofit / OkHttp / Okio ──────────────────────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn retrofit2.**
-dontwarn javax.annotation.**
-keep class retrofit2.** { *; }

# Retrofit reads the service interface's annotations reflectively — keep ours.
-keep interface video.crumb.app.data.** { *; }
-keepclassmembers,allowshrinking,allowobfuscation interface * {
    @retrofit2.http.* <methods>;
}

# ── Media3 / ExoPlayer ────────────────────────────────────────────────────────
-dontwarn androidx.media3.**

# ── Coil ──────────────────────────────────────────────────────────────────────
-dontwarn coil.**
