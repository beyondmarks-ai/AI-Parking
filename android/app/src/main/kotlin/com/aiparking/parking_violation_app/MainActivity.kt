package com.aiparking.parking_violation_app

import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import com.google.firebase.messaging.FirebaseMessaging
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.wifi.WifiManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

class MainActivity : FlutterActivity() {
    private val channelName = "parkguard/video_picker"
    private val pickVideoRequest = 7001
    private var pendingResult: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val textRecognizerDelegate = lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }
    private val textRecognizer
        get() = textRecognizerDelegate.value
    private var ocrBusy = false
    private var bayBuzzer: ToneGenerator? = null

    override fun onPause() {
        bayBuzzer?.stopTone()
        super.onPause()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("parkguard-camera-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        bayBuzzer?.release()
        bayBuzzer = null
        // Do not initialize ML Kit solely to close it during an early activity
        // recreation (for example, a rotation before the first OCR request).
        if (textRecognizerDelegate.isInitialized()) {
            textRecognizerDelegate.value.close()
        }
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parkguard/account_session").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "load" -> result.success(AccountStorage.load(this))
                    "save" -> {
                        AccountStorage.save(this, call.argument<String>("token")!!, call.argument<String>("userId")!!, call.argument<String>("api")!!)
                        result.success(null)
                    }
                    "clear" -> { AccountStorage.clear(this); result.success(null) }
                    "notification" -> {
                        val penalty = intent.getStringExtra("penalty_id")
                        intent.removeExtra("penalty_id")
                        result.success(penalty)
                    }
                    "pushToken" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7002)
                        }
                        FirebaseMessaging.getInstance().token.addOnSuccessListener { result.success(it) }
                            .addOnFailureListener { result.error("PUSH_FAILED", "Could not register notifications", null) }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("SESSION_FAILED", error.message, null) }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parkguard/bay_buzzer").setMethodCallHandler { call, result ->
            if (call.method != "buzz") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val tone = bayBuzzer ?: ToneGenerator(AudioManager.STREAM_MUSIC, 90).also {
                    bayBuzzer = it
                }
                tone.stopTone()
                if (tone.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 1200)) {
                    result.success(null)
                } else {
                    result.error("BUZZER_FAILED", "Could not start the bay alert sound", null)
                }
            } catch (error: Exception) {
                result.error("BUZZER_FAILED", error.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parkguard/parking_zone").setMethodCallHandler { call, result ->
            val camera = call.argument<String>("camera")
            if (camera.isNullOrBlank() || camera.length > 2048) {
                result.error("INVALID_CAMERA", "A camera URL is required", null)
                return@setMethodCallHandler
            }
            val preferences = getSharedPreferences("parking_zones", Context.MODE_PRIVATE)
            when (call.method) {
                "load" -> result.success(preferences.getString(camera, null))
                "save" -> {
                    val zone = call.argument<String>("zone")
                    if (zone == null || zone.length > 2048) {
                        result.error("INVALID_ZONE", "A bounded zone is required", null)
                    } else if (preferences.edit().putString(camera, zone).commit()) {
                        result.success(null)
                    } else {
                        result.error("SAVE_FAILED", "Could not save the bay", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "parkguard/plate_ocr").setMethodCallHandler { call, result ->
            if (call.method != "recognize") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("jpeg")
            if (bytes == null || bytes.isEmpty() || bytes.size > 10_000_000) {
                result.error("INVALID_IMAGE", "A camera image is required.", null)
                return@setMethodCallHandler
            }
            if (ocrBusy) {
                result.error("OCR_BUSY", "A number is already being read.", null)
                return@setMethodCallHandler
            }
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bitmap == null) {
                result.error("INVALID_IMAGE", "The camera frame could not be decoded.", null)
                return@setMethodCallHandler
            }
            ocrBusy = true
            try {
                textRecognizer.process(InputImage.fromBitmap(bitmap, 0))
                    .addOnSuccessListener { text ->
                        // Include a padded region around digit-bearing blocks.
                        // This preserves two-line plates and falls back to the
                        // full image if local OCR cannot locate any text.
                        val boxes = text.textBlocks
                            .filter { block -> block.text.any { it.isDigit() } }
                            .mapNotNull { it.boundingBox }
                        val box = if (boxes.isEmpty()) null else listOf(
                            ((boxes.minOf { it.left } - 16).coerceAtLeast(0)).toDouble() / bitmap.width,
                            ((boxes.minOf { it.top } - 16).coerceAtLeast(0)).toDouble() / bitmap.height,
                            ((boxes.maxOf { it.right } + 16).coerceAtMost(bitmap.width)).toDouble() / bitmap.width,
                            ((boxes.maxOf { it.bottom } + 16).coerceAtMost(bitmap.height)).toDouble() / bitmap.height,
                        )
                        result.success(mapOf("text" to text.text, "plateBox" to box))
                    }
                    .addOnFailureListener { error ->
                        result.error("OCR_FAILED", error.message ?: "Text recognition failed.", null)
                    }
                    .addOnCompleteListener {
                        ocrBusy = false
                        bitmap.recycle()
                    }
            } catch (error: Exception) {
                ocrBusy = false
                bitmap.recycle()
                result.error("OCR_FAILED", error.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            if (call.method != "pickVideo") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (pendingResult != null) {
                result.error("PICKER_BUSY", "A video picker is already open.", null)
                return@setMethodCallHandler
            }
            pendingResult = result
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "video/*"
            }, pickVideoRequest)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickVideoRequest) return
        val result = pendingResult ?: return
        pendingResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        result.success(displayName(uri))
    }

    private fun displayName(uri: Uri): String {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, null, null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)) ?: "Selected video"
            } else "Selected video"
        } finally {
            cursor?.close()
        }
    }
}
