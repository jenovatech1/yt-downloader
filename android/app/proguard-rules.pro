# yt-dlp / youtubedl-android (Seal-compatible)
# Release crash on initPython: ExceptionInInitializerError in ZipUtils
# tanpa keep commons-compress + SourceFile (youtubedl-android#234).
-dontobfuscate
-keepattributes SourceFile,LineNumberTable,InnerClasses,EnclosingMethod,*Annotation*

-keep class com.yausername.** { *; }
-keep class org.apache.commons.compress.** { *; }
-keep class com.ashishpipaliya.extractor.** { *; }
-dontwarn com.yausername.**
-dontwarn org.apache.commons.compress.**

# Flutter / plugins
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Legacy NewPipe remnants (harmless if unused)
-dontwarn java.beans.**
-dontwarn javax.script.**
-keep class org.mozilla.javascript.** { *; }
-keep class org.schabi.newpipe.** { *; }
-keep class com.github.TeamNewPipe.** { *; }
-keep class okhttp3.** { *; }
