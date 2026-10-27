package com.omergirgin.mosaic.data.connections

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.omergirgin.mosaic.core.connections.ConnectorCredential
import com.omergirgin.mosaic.core.connections.ConnectorVault
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.json.Json

/**
 * Connection credentials (tokens, refresh tokens, account labels), sealed with their own Android
 * Keystore AES-256-GCM key in a separate private preferences file — the same pattern as the
 * provider-key `SecretStore`, never in Room. Each ciphertext is bound to its credential key as GCM
 * associated data, so an entry can't be replayed under another service. The generation ID is kept
 * in plaintext next to it (not secret) so frequent validation needs no decryption.
 *
 * Calls are synchronous (`commit`) on purpose: `ConnectorStore` performs them inside its lock so a
 * write finishes before a concurrent disconnect can run. The manifest excludes shared preferences
 * from backup and device transfer.
 */
internal class ConnectionVault(context: Context) : ConnectorVault {
  private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
  private val json = Json { ignoreUnknownKeys = true }
  @Volatile private var cachedKey: SecretKey? = null

  override fun load(key: String): ConnectorCredential? {
    val stored = prefs.getString(cipherEntry(key), null) ?: return null
    return try {
      json.decodeFromString(ConnectorCredential.serializer(), decrypt(stored, aad(key)))
    } catch (_: Exception) {
      // Deliberately not logged: the exception could describe key material. Unreadable = absent.
      null
    }
  }

  override fun generation(key: String): String? =
    prefs.getString(generationEntry(key), null)?.takeIf { prefs.contains(cipherEntry(key)) }

  override fun save(value: ConnectorCredential, key: String) {
    val sealed = encrypt(json.encodeToString(ConnectorCredential.serializer(), value), aad(key))
    val committed = prefs.edit().putString(cipherEntry(key), sealed).putString(generationEntry(key), value.id).commit()
    check(committed) { "The connection could not be saved on this device." }
  }

  override fun clear(key: String) {
    val committed = prefs.edit().remove(cipherEntry(key)).remove(generationEntry(key)).commit()
    check(committed) { "The connection could not be removed from this device." }
  }

  private fun encrypt(plaintext: String, aad: ByteArray): String {
    val cipher = Cipher.getInstance(TRANSFORMATION)
    cipher.init(Cipher.ENCRYPT_MODE, secretKey())
    cipher.updateAAD(aad)
    val bytes = plaintext.toByteArray(Charsets.UTF_8)
    try {
      return FORMAT_PREFIX + encode(cipher.iv) + ":" + encode(cipher.doFinal(bytes))
    } finally {
      bytes.fill(0)
    }
  }

  private fun decrypt(stored: String, aad: ByteArray): String {
    require(stored.startsWith(FORMAT_PREFIX))
    val parts = stored.removePrefix(FORMAT_PREFIX).split(':')
    require(parts.size == 2)
    val cipher = Cipher.getInstance(TRANSFORMATION)
    cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, decode(parts[0])))
    cipher.updateAAD(aad)
    val bytes = cipher.doFinal(decode(parts[1]))
    try {
      return String(bytes, Charsets.UTF_8)
    } finally {
      bytes.fill(0)
    }
  }

  private fun secretKey(): SecretKey {
    cachedKey?.let { return it }
    synchronized(this) {
      cachedKey?.let { return it }
      val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
      val existing = (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
      val key = existing ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).run {
        init(
          KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        )
        generateKey()
      }
      cachedKey = key
      return key
    }
  }

  private fun aad(key: String) = "$AAD_PREFIX|$key".toByteArray(Charsets.UTF_8)
  private fun cipherEntry(key: String) = "credential.$key"
  private fun generationEntry(key: String) = "generation.$key"
  private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
  private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)

  private companion object {
    const val PREFS_FILE = "turing_connection_credentials"
    const val ANDROID_KEYSTORE = "AndroidKeyStore"
    const val KEY_ALIAS = "turing_connection_keys_v1"
    const val TRANSFORMATION = "AES/GCM/NoPadding"
    const val TAG_BITS = 128
    const val FORMAT_PREFIX = "v1:"
    const val AAD_PREFIX = "turing-connection-v1"
  }
}
