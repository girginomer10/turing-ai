package com.omergirgin.mosaic.data.security

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.omergirgin.mosaic.core.chat.CredentialBinding
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Result of reading one provider key. Never carries key material except in [Present]. */
internal sealed interface StoredKey {
  data object Missing : StoredKey
  /** Saved for a different adapter or endpoint; must be re-entered for this destination. */
  data object BindingMismatch : StoredKey
  /** Ciphertext exists but can no longer be decrypted (Keystore key lost or data tampered). */
  data object Unreadable : StoredKey
  class Present(val apiKey: String) : StoredKey {
    override fun toString(): String = "Present(••••)"
  }
}

/** Opaque rollback state for one provider's stored key. Callers never decode it. */
internal class CredentialSnapshot internal constructor(
  internal val ciphertext: String?,
  internal val binding: String?,
)

/**
 * The only component that accepts or returns provider API keys (iOS `SecurityKeychain`).
 *
 * - One AES-256-GCM key in Android Keystore (non-exportable, hardware-backed where available).
 * - One ciphertext per provider config in a private SharedPreferences file; the app manifest and
 *   data-extraction rules exclude it from cloud backup and device transfer (a restored ciphertext
 *   could not be decrypted without the device-bound Keystore key anyway).
 * - Each key is bound to [CredentialBinding.storageKey] (adapter + exact normalized endpoint). The
 *   binding is authenticated as GCM associated data, so a key saved for one destination is never
 *   released for another, even if the plaintext binding entry were edited on disk.
 *
 * Key material is never logged; [StoredKey.Present.toString] is redacted.
 */
internal class SecretStore(context: Context) {
  private val prefs: SharedPreferences =
    context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
  private val mutex = Mutex()
  @Volatile private var cachedKey: SecretKey? = null

  private val _changes = MutableStateFlow(0L)
  /** Bumps after every write so observers can recompute `hasApiKey`. */
  val changes: StateFlow<Long> = _changes.asStateFlow()

  /** Cheap presence check (no decryption): a key exists and is bound to [binding]. */
  fun hasKey(configId: String, binding: CredentialBinding): Boolean =
    prefs.getString(cipherEntry(configId), null) != null &&
      prefs.getString(bindingEntry(configId), null) == binding.storageKey

  suspend fun read(configId: String, expected: CredentialBinding): StoredKey = withContext(Dispatchers.IO) {
    mutex.withLock {
      val stored = prefs.getString(cipherEntry(configId), null) ?: return@withLock StoredKey.Missing
      val storedBinding = prefs.getString(bindingEntry(configId), null)
      if (storedBinding != expected.storageKey) return@withLock StoredKey.BindingMismatch
      try {
        StoredKey.Present(decrypt(stored, associatedData(configId, expected.storageKey)))
      } catch (_: Exception) {
        // Deliberately not logged: the exception could describe key material.
        StoredKey.Unreadable
      }
    }
  }

  suspend fun write(configId: String, apiKey: String, binding: CredentialBinding) {
    require(apiKey.isNotBlank()) { "The API key cannot be empty." }
    withContext(Dispatchers.IO) {
      mutex.withLock {
        val ciphertext = encrypt(apiKey, associatedData(configId, binding.storageKey))
        val committed = prefs.edit()
          .putString(cipherEntry(configId), ciphertext)
          .putString(bindingEntry(configId), binding.storageKey)
          .commit()
        check(committed) { "The API key could not be saved on this device." }
      }
    }
    _changes.update { it + 1 }
  }

  suspend fun remove(configId: String) {
    withContext(Dispatchers.IO) {
      mutex.withLock {
        val committed = prefs.edit().remove(cipherEntry(configId)).remove(bindingEntry(configId)).commit()
        check(committed) { "The API key could not be removed from this device." }
      }
    }
    _changes.update { it + 1 }
  }

  suspend fun snapshot(configId: String): CredentialSnapshot = withContext(Dispatchers.IO) {
    mutex.withLock {
      CredentialSnapshot(prefs.getString(cipherEntry(configId), null), prefs.getString(bindingEntry(configId), null))
    }
  }

  /** Restores exactly the bytes captured by [snapshot] without decoding or rebinding them. */
  suspend fun restore(configId: String, snapshot: CredentialSnapshot) {
    withContext(Dispatchers.IO) {
      mutex.withLock {
        val editor = prefs.edit()
        if (snapshot.ciphertext != null && snapshot.binding != null) {
          editor.putString(cipherEntry(configId), snapshot.ciphertext)
          editor.putString(bindingEntry(configId), snapshot.binding)
        } else {
          editor.remove(cipherEntry(configId)).remove(bindingEntry(configId))
        }
        editor.commit()
      }
    }
    _changes.update { it + 1 }
  }

  private fun encrypt(plaintext: String, aad: ByteArray): String {
    val cipher = Cipher.getInstance(TRANSFORMATION)
    // Keystore generates a fresh random IV per encryption (randomized encryption is required).
    cipher.init(Cipher.ENCRYPT_MODE, secretKey())
    cipher.updateAAD(aad)
    val bytes = plaintext.toByteArray(Charsets.UTF_8)
    try {
      val sealed = cipher.doFinal(bytes)
      return FORMAT_PREFIX + encode(cipher.iv) + ":" + encode(sealed)
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

  private fun associatedData(configId: String, storageKey: String): ByteArray =
    "$AAD_PREFIX|$configId|$storageKey".toByteArray(Charsets.UTF_8)

  private fun cipherEntry(configId: String) = "key.$configId"
  private fun bindingEntry(configId: String) = "binding.$configId"
  private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
  private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)

  private companion object {
    const val PREFS_FILE = "turing_provider_credentials"
    const val ANDROID_KEYSTORE = "AndroidKeyStore"
    const val KEY_ALIAS = "turing_provider_keys_v1"
    const val TRANSFORMATION = "AES/GCM/NoPadding"
    const val TAG_BITS = 128
    const val FORMAT_PREFIX = "v1:"
    const val AAD_PREFIX = "turing-provider-key-v1"
  }
}
