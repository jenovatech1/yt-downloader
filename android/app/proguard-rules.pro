# NewPipe / Rhino (youtube_muxer_2025)
-dontwarn java.beans.BeanDescriptor
-dontwarn java.beans.BeanInfo
-dontwarn java.beans.IntrospectionException
-dontwarn java.beans.Introspector
-dontwarn java.beans.PropertyDescriptor
-dontwarn javax.script.ScriptEngineFactory
-keep class org.mozilla.javascript.** { *; }
-keep class org.schabi.newpipe.** { *; }
-keep class com.github.TeamNewPipe.** { *; }
-keep class okhttp3.** { *; }
-dontwarn org.mozilla.javascript.**

# yt-dlp / youtubedl-android
-keep class com.yausername.** { *; }
-keep class com.ashishpipaliya.extractor.** { *; }
-dontwarn com.yausername.**
