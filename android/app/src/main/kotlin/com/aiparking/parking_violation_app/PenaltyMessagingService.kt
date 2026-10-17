package com.aiparking.parking_violation_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.net.HttpURLConnection
import java.net.URI
import org.json.JSONObject

class PenaltyMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val owner = message.data["owner_id"] ?: return
        val penalty = message.data["penalty_id"] ?: return
        if (AccountStorage.userId(this) != owner || AccountStorage.load(this) == null) return
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel("penalties", "Parking penalties", NotificationManager.IMPORTANCE_HIGH))
        val intent = Intent(this, MainActivity::class.java).putExtra("penalty_id", penalty)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(this, penalty.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "penalties") else Notification.Builder(this)
        manager.notify(penalty.hashCode(), builder.setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("New parking penalty")
            .setContentText("Open ParkGuard to view your vehicle, evidence and payment options.")
            .setContentIntent(pending).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).build())
    }
    override fun onNewToken(token: String) {
        // Firebase invokes this on a background thread. Registration also runs
        // on every sign-in/app start so offline refreshes are retried.
        val session = AccountStorage.load(this) ?: return
        val api = getSharedPreferences("account", Context.MODE_PRIVATE).getString("api", null) ?: return
        if (!api.startsWith("https://")) return
        try {
            val connection = URI("$api/api/v1/push/register").toURL().openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = 5000; connection.readTimeout = 5000
                connection.setRequestProperty("Authorization", "Bearer $session")
                connection.setRequestProperty("Content-Type", "application/json")
                connection.doOutput = true
                connection.outputStream.use { it.write(JSONObject().put("token", token).toString().toByteArray()) }
                connection.responseCode
            } finally { connection.disconnect() }
        } catch (_: Exception) { /* Retry during the next app start. */ }
    }
}
