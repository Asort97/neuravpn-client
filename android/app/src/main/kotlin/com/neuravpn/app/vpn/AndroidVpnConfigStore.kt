package com.neuravpn.app.vpn

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keystore-backed storage used by the Quick Settings tile reconnect action. */
object AndroidVpnConfigStore {
    private const val KEY_ALIAS = "neuravpn_quick_tile_config"
    private const val FILE_NAME = "neuravpn_last_config.enc"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    fun save(context: Context, payload: JSONObject) {
        runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            val encrypted = cipher.doFinal(payload.toString().toByteArray(Charsets.UTF_8))
            val envelope = JSONObject().apply {
                put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                put("data", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            }
            atomicWrite(File(context.filesDir, FILE_NAME), envelope.toString())
            File(context.filesDir, "neuravpn_last_config.json").delete()
        }
    }

    fun read(context: Context): JSONObject? = runCatching {
        val file = File(context.filesDir, FILE_NAME)
        if (!file.exists()) return null
        val envelope = JSONObject(file.readText(Charsets.UTF_8))
        val iv = Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)
        val encrypted = Base64.decode(envelope.getString("data"), Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        JSONObject(String(cipher.doFinal(encrypted), Charsets.UTF_8))
    }.getOrNull()

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private fun atomicWrite(target: File, content: String) {
        val temp = File(target.parentFile, "$FILE_NAME.tmp")
        FileOutputStream(temp).use { output ->
            output.write(content.toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = true)
            temp.delete()
        }
    }
}
