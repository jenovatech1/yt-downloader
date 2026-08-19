package com.agung.ytdownloader.yt_downloader

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "yt_downloader/klippod"
    private val tag = "KlippodOpen"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
