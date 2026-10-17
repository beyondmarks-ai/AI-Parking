package com.aiparking.parking_violation_app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object AccountStorage {
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("parkguard-session", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("parkguard-session", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun save(context: Context, token: String, userId: String, api: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        check(context.getSharedPreferences("account", Context.MODE_PRIVATE).edit()
            .putString("token", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("user", userId).putString("api", api).commit())
    }
    fun load(context: Context): String? {
        val prefs = context.getSharedPreferences("account", Context.MODE_PRIVATE)
        val token = prefs.getString("token", null) ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)))
            }
            String(cipher.doFinal(Base64.decode(token, Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: Exception) { clear(context); null }
    }
    fun userId(context: Context): String? = context.getSharedPreferences("account", Context.MODE_PRIVATE).getString("user", null)
    fun clear(context: Context) {
        context.getSharedPreferences("account", Context.MODE_PRIVATE).edit().clear().commit()
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager).cancelAll()
    }
}
