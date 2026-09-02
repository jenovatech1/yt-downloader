package com.agung.ytdownloader.yt_downloader

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "yt_downloader/klippod"
    private val updaterChannelName = "yt_downloader/updater"
    private val filesChannelName = "yt_downloader/files"
    private val ytdlpChannelName = "yt_downloader/ytdlp"
    private val ytdlpExecutor = Executors.newSingleThreadExecutor()
    private val tag = "KlippodOpen"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updaterChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(installApk(path))
                        } catch (e: Exception) {
                            Log.e(tag, "installApk failed", e)
                            result.error("install_failed", e.message ?: e.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filesChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "savePublicText" -> {
                        val fileName = call.argument<String>("fileName")
                        val content = call.argument<String>("content")
                        if (fileName.isNullOrBlank() || content == null) {
                            result.error("bad_args", "fileName/content required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(savePublicText(fileName, content))
                        } catch (e: Exception) {
                            Log.e(tag, "savePublicText failed", e)
                            result.error("save_failed", e.message ?: e.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ytdlpChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dumpVideoJson" -> {
                        val videoId = call.argument<String>("videoId")
                        val format = call.argument<String>("format")
                        if (videoId.isNullOrBlank()) {
                            result.error("bad_args", "videoId required", null)
                            return@setMethodCallHandler
                        }
                        ytdlpExecutor.execute {
                            try {
                                YoutubeDL.getInstance().init(applicationContext)
                                val url = "https://www.youtube.com/watch?v=$videoId"
                                val request = YoutubeDLRequest(url)
                                request.addOption("--no-update")
                                request.addOption("-j")
                                request.addOption("--skip-download")
                                if (!format.isNullOrBlank()) {
                                    request.addOption("-f", format)
                                }
                                request.addOption(
                                    "--extractor-args",
                                    "youtube:player_client=default,-android_sdkless",
                                )
                                val response = YoutubeDL.getInstance().execute(request)
                                val out = response.out.trim()
                                if (out.isEmpty()) {
                                    throw IllegalStateException("yt-dlp -j kosong")
                                }
                                runOnUiThread { result.success(out) }
                            } catch (e: Exception) {
                                Log.e(tag, "dumpVideoJson failed", e)
                                runOnUiThread {
                                    result.error(
                                        "ytdlp_json_failed",
                                        e.message ?: e.toString(),
                                        null,
                                    )
                                }
                            }
                        }
                    }
                    "muxLocalClip" -> {
                        val videoPath = call.argument<String>("videoPath")
                        val audioPath = call.argument<String>("audioPath")
                        val outputPath = call.argument<String>("outputPath")
                        val videoTrim = call.argument<Double>("videoTrimStartSec") ?: 0.0
                        val audioTrim = call.argument<Double>("audioTrimStartSec") ?: videoTrim
                        val duration = call.argument<Double>("durationSec")
                        if (videoPath.isNullOrBlank() ||
                            outputPath.isNullOrBlank() ||
                            duration == null ||
                            duration <= 0.0
                        ) {
                            result.error("bad_args", "mux arguments invalid", null)
                            return@setMethodCallHandler
                        }
                        ytdlpExecutor.execute {
                            try {
                                val out = muxLocalClip(
                                    videoPath,
                                    audioPath,
                                    outputPath,
                                    videoTrim,
                                    audioTrim,
                                    duration,
                                )
                                runOnUiThread { result.success(out) }
                            } catch (e: Exception) {
                                Log.e(tag, "muxLocalClip failed", e)
                                runOnUiThread {
                                    result.error(
                                        "ffmpeg_mux_failed",
                                        e.message ?: e.toString(),
                                        null,
                                    )
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openInKlippod" -> {
                        val path = call.argument<String>("path")
                        val packageName = call.argument<String>("packageName")
                        val title = call.argument<String>("title") ?: "Video"
                        if (path.isNullOrBlank() || packageName.isNullOrBlank()) {
                            result.error("bad_args", "path/packageName required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(openInKlippod(path, packageName, title))
                        } catch (e: Exception) {
                            Log.e(tag, "openInKlippod failed", e)
                            result.error("open_failed", e.message ?: e.toString(), null)
                        }
                    }
                    "openClipsInKlippod" -> {
                        val paths = call.argument<ArrayList<String>>("paths")
                        val packageName = call.argument<String>("packageName")
                        val title = call.argument<String>("title") ?: "Klip YouTube"
                        val youtubeUrl = call.argument<String>("youtubeUrl")
                        val hooksJson = call.argument<String>("hooksJson")
                        if (paths.isNullOrEmpty() || packageName.isNullOrBlank()) {
                            result.error("bad_args", "paths/packageName required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(
                                openClipsInKlippod(
                                    paths,
                                    packageName,
                                    title,
                                    youtubeUrl,
                                    hooksJson,
                                ),
                            )
                        } catch (e: Exception) {
                            Log.e(tag, "openClipsInKlippod failed", e)
                            result.error("open_failed", e.message ?: e.toString(), null)
                        }
                    }
                    "isKlippodInstalled" -> {
                        val packageName = call.argument<String>("packageName")
                        if (packageName.isNullOrBlank()) {
                            result.error("bad_args", "packageName required", null)
                            return@setMethodCallHandler
                        }
                        result.success(isPackageInstalled(packageName))
                    }
                    "openPlayStore" -> {
                        val packageName = call.argument<String>("packageName")
                        if (packageName.isNullOrBlank()) {
                            result.error("bad_args", "packageName required", null)
                            return@setMethodCallHandler
                        }
                        openPlayStore(packageName)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun muxLocalClip(
        videoPath: String,
        audioPath: String?,
        outputPath: String,
        videoTrimStartSec: Double,
        audioTrimStartSec: Double,
        durationSec: Double,
    ): String {
        val video = File(videoPath)
        if (!video.exists() || video.length() < 2048L) {
            throw IllegalStateException("Input video tidak valid")
        }
        val audio = audioPath?.let(::File)
        if (audioPath != null && (audio == null || !audio.exists() || audio.length() < 1024L)) {
            throw IllegalStateException("Input audio tidak valid")
        }

        FFmpeg.getInstance().init(applicationContext)
        val ffmpeg = File(applicationInfo.nativeLibraryDir, "libffmpeg.so")
        if (!ffmpeg.exists()) throw IllegalStateException("FFmpeg tidak ditemukan")

        val output = File(outputPath)
        output.parentFile?.mkdirs()
        if (output.exists()) output.delete()

        val command = mutableListOf(
            ffmpeg.absolutePath,
            "-y",
            "-ss",
            String.format(java.util.Locale.US, "%.3f", videoTrimStartSec),
            "-i",
            video.absolutePath,
        )
        if (audio != null) {
            command.addAll(
                listOf(
                    "-ss",
                    String.format(java.util.Locale.US, "%.3f", audioTrimStartSec),
                    "-i",
                    audio.absolutePath,
                ),
            )
        }
        command.addAll(listOf("-t", String.format(java.util.Locale.US, "%.3f", durationSec)))
        if (audio != null) {
            command.addAll(listOf("-map", "0:v:0", "-map", "1:a:0"))
        } else {
            command.addAll(listOf("-map", "0:v:0", "-map", "0:a?"))
        }
        command.addAll(
            listOf(
                "-c",
                "copy",
                "-avoid_negative_ts",
                "make_zero",
                "-movflags",
                "+faststart",
                output.absolutePath,
            ),
        )

        val processBuilder = ProcessBuilder(command).redirectErrorStream(true)
        val packagesDir = File(noBackupFilesDir, "youtubedl-android/packages")
        val pythonLibDir = File(packagesDir, "python/usr/lib")
        val ffmpegLibDir = File(packagesDir, "ffmpeg/usr/lib")
        val aria2cLibDir = File(packagesDir, "aria2c/usr/lib")
        processBuilder.environment()["LD_LIBRARY_PATH"] =
            "${pythonLibDir.absolutePath}:${ffmpegLibDir.absolutePath}:" +
            "${aria2cLibDir.absolutePath}:${applicationInfo.nativeLibraryDir}"
        val process = processBuilder.start()
        val log = process.inputStream.bufferedReader().use { it.readText() }
        val exitCode = process.waitFor()
        if (exitCode != 0 || !output.exists() || output.length() < 2048L) {
            throw IllegalStateException(
                "FFmpeg gagal ($exitCode): ${log.takeLast(1200)}",
            )
        }
        if (audio != null && !log.contains("Audio:", ignoreCase = true)) {
            output.delete()
            throw IllegalStateException("FFmpeg tidak menemukan track audio")
        }
        return output.absolutePath
    }

    private fun savePublicText(fileName: String, content: String): Map<String, String> {
        val safeName = fileName
            .replace(Regex("""[\\/:*?"<>|]"""), "_")
            .trim()
            .ifEmpty { "transkrip_clip.txt" }
        val displayName = if (safeName.endsWith(".txt", ignoreCase = true)) {
            safeName
        } else {
            "$safeName.txt"
        }
        val folder = "YT Downloader"
        val relative = "${Environment.DIRECTORY_DOCUMENTS}/$folder"
        val bytes = content.toByteArray(StandardCharsets.UTF_8)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = contentResolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore insert gagal")
            contentResolver.openOutputStream(uri)?.use { out ->
                out.write(bytes)
                out.flush()
            } ?: throw IllegalStateException("Tidak bisa tulis file")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return mapOf(
                "uri" to uri.toString(),
                "displayName" to displayName,
                "location" to "Documents/$folder/$displayName",
            )
        }

        @Suppress("DEPRECATION")
        val docs = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
        val dir = File(docs, folder)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("Gagal buat folder Documents/$folder")
        }
        val file = File(dir, displayName)
        FileOutputStream(file).use { out ->
            out.write(bytes)
            out.flush()
        }
        // Biar muncul di Recent / file picker.
        val scanValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DATA, file.absolutePath)
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
        }
        contentResolver.insert(MediaStore.Files.getContentUri("external"), scanValues)
        return mapOf(
            "uri" to Uri.fromFile(file).toString(),
            "displayName" to displayName,
            "location" to "Documents/$folder/$displayName",
            "path" to file.absolutePath,
        )
    }

    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("APK tidak ditemukan: $path")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
            return "need_permission"
        }

        val uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file,
        )
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
        )
        return "ok"
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    android.content.pm.PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openPlayStore(packageName: String) {
        try {
            startActivity(
                Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("market://details?id=$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: ActivityNotFoundException) {
            startActivity(
                Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://play.google.com/store/apps/details?id=$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    private fun openInKlippod(path: String, packageName: String, title: String): String {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("File tidak ditemukan: $path")
        }

        val authority = "${applicationContext.packageName}.fileprovider"
        val uri = try {
            FileProvider.getUriForFile(this, authority, file)
        } catch (e: IllegalArgumentException) {
            throw IllegalStateException(
                "FileProvider gagal untuk path=$path authority=$authority (${e.message})",
                e,
            )
        }

        grantUriPermission(
            packageName,
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
        )

        // Jangan set type= setelah setData — di Android itu menghapus data URI.
        val deepLink = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse("klippod://import")
            setPackage(packageName)
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TITLE, title)
            putExtra("video_uri", uri.toString())
            putExtra("source", "yt_downloader")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val send = Intent(Intent.ACTION_SEND).apply {
            setPackage(packageName)
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TITLE, title)
            putExtra("video_uri", uri.toString())
            putExtra("source", "yt_downloader")
            clipData = android.content.ClipData.newUri(contentResolver, title, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val view = Intent(Intent.ACTION_VIEW).apply {
            setPackage(packageName)
            setDataAndType(uri, "video/mp4")
            putExtra("video_uri", uri.toString())
            putExtra("source", "yt_downloader")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val attempts = listOf(
            "deep_link" to deepLink,
            "send" to send,
            "view" to view,
        )

        for ((name, intent) in attempts) {
            try {
                startActivity(intent)
                Log.i(tag, "Opened Klippod via $name")
                return name
            } catch (e: ActivityNotFoundException) {
                Log.w(tag, "No activity for $name", e)
            } catch (e: Exception) {
                Log.w(tag, "Failed $name", e)
            }
        }

        if (!isPackageInstalled(packageName)) {
            return "not_installed"
        }

        throw IllegalStateException(
            "Klippod terpasang ($packageName) tapi belum ada intent-filter untuk terima video. " +
                "Pastikan Klippod sudah support klippod://import / ACTION_SEND video.",
        )
    }

    private fun openClipsInKlippod(
        paths: ArrayList<String>,
        packageName: String,
        title: String,
        youtubeUrl: String?,
        hooksJson: String?,
    ): String {
        val authority = "${applicationContext.packageName}.fileprovider"
        val uris = ArrayList<Uri>()
        for (path in paths) {
            val file = File(path)
            if (!file.exists()) {
                throw IllegalStateException("File klip tidak ditemukan: $path")
            }
            val uri = FileProvider.getUriForFile(this, authority, file)
            grantUriPermission(packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            uris.add(uri)
        }
        if (uris.isEmpty()) {
            throw IllegalStateException("Tidak ada file klip")
        }

        val clip = ClipData.newUri(contentResolver, title, uris[0])
        for (i in 1 until uris.size) {
            clip.addItem(ClipData.Item(uris[i]))
        }

        fun Intent.withClipExtras(): Intent {
            putExtra("import_kind", "clips")
            putExtra(Intent.EXTRA_TITLE, title)
            putExtra("source", "yt_downloader")
            if (!youtubeUrl.isNullOrBlank()) putExtra("youtube_url", youtubeUrl)
            if (!hooksJson.isNullOrBlank()) {
                putExtra("hooks_json", hooksJson)
                putExtra(Intent.EXTRA_TEXT, hooksJson)
            }
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            clipData = clip
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            setPackage(packageName)
            return this
        }

        val deepLink = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse("klippod://import-clips")
            withClipExtras()
        }
        val send = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "video/mp4"
            withClipExtras()
        }

        val attempts = listOf("deep_link_clips" to deepLink, "send_multiple" to send)
        for ((name, intent) in attempts) {
            try {
                startActivity(intent)
                Log.i(tag, "Opened Klippod clips via $name")
                return name
            } catch (e: ActivityNotFoundException) {
                Log.w(tag, "No activity for $name", e)
            } catch (e: Exception) {
                Log.w(tag, "Failed $name", e)
            }
        }

        if (!isPackageInstalled(packageName)) {
            return "not_installed"
        }
        throw IllegalStateException(
            "Klippod terpasang tapi belum bisa menerima banyak klip. Update Klippod dulu.",
        )
    }
}
