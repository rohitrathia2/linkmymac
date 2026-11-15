package com.linkmymac.android.crypto

import android.content.Context
import android.os.SystemClock
import android.util.Base64
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Decides which Macs may talk to this phone.
 *
 * Pairing (once): the Mac sends the 6-character code shown in the app plus an ephemeral
 * P-256 public key. If the code matches, both sides derive a 256-bit secret from ECDH,
 * so the secret itself never crosses the wire.
 *
 * Every connection after that: the phone sends a fresh nonce (AUTH_CHALLENGE) and the
 * Mac answers HMAC(secret, "mac|" + nonce). The phone answers the Mac's nonce the same
 * way ("phone|"), so a fake phone on the network can't impersonate this one either.
 */
object PairingManager {
    private const val PREFS = "linkmymac_pairing"
    private const val MAC_PREFIX = "mac."
    private const val CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789" // no 0/O/1/I/L
    private const val CODE_LENGTH = 6 // 31^6 ≈ 8.9e8 codes
    // A wrong code blocks every code attempt for 3 s: brute force would take decades.
    private const val FAILED_CODE_COOLDOWN_MS = 3_000L

    private val random = SecureRandom()
    private var lastFailedCodeAt = -FAILED_CODE_COOLDOWN_MS

    /** Shown on the phone, typed or QR-scanned on the Mac. Single use. */
    @Volatile
    var pairingCode: String = newCode()
        private set

    sealed class Result {
        /** [phonePublicKey] is set only when this handshake created a new pairing. */
        class Accepted(val secret: ByteArray, val phonePublicKey: String?) : Result()
        class Rejected(val reason: String) : Result()
    }

    @Synchronized
    fun rotateCode() {
        pairingCode = newCode()
    }

    fun newNonce(): String = randomBytes(16).toHex()

    /** Random per-install id so the Mac can tell phones apart without hardware identifiers. */
    @Synchronized
    fun phoneId(context: Context): String {
        val prefs = prefs(context)
        prefs.getString("phone_id", null)?.let { return it }
        return UUID.randomUUID().toString().also { prefs.edit().putString("phone_id", it).apply() }
    }

    fun pairedMacCount(context: Context): Int =
        prefs(context).all.keys.count { it.startsWith(MAC_PREFIX) }

    fun forgetMac(context: Context, deviceId: String) {
        prefs(context).edit().remove(MAC_PREFIX + deviceId).commit()
    }

    fun forgetAllMacs(context: Context) {
        val prefs = prefs(context)
        val editor = prefs.edit()
        prefs.all.keys.filter { it.startsWith(MAC_PREFIX) }.forEach { editor.remove(it) }
        editor.commit()
    }

    /** HMAC proof that the sender holds [secret], bound to the peer's [nonce]. */
    fun proof(secret: ByteArray, role: String, nonce: String): String =
        hmac(secret, "$role|$nonce".toByteArray(Charsets.UTF_8)).toHex()

    @Synchronized
    fun authenticate(
        context: Context,
        deviceId: String,
        nonce: String,
        proof: String,
        code: String,
        macPublicKey: String
    ): Result {
        if (deviceId.isBlank()) return Result.Rejected("PAIRING_REQUIRED")
        val prefs = prefs(context)

        // Reconnect of an already-paired Mac.
        if (proof.isNotEmpty()) {
            val stored = prefs.getString(MAC_PREFIX + deviceId, null)
                ?: return Result.Rejected("PAIRING_REQUIRED")
            val secret = Base64.decode(stored, Base64.NO_WRAP)
            val expected = proof(secret, "mac", nonce)
            return if (MessageDigest.isEqual(expected.toByteArray(), proof.lowercase().toByteArray())) {
                Result.Accepted(secret, phonePublicKey = null)
            } else {
                Result.Rejected("PAIRING_REQUIRED")
            }
        }

        // First pairing with the on-screen code.
        val typed = code.uppercase().filter { it.isLetterOrDigit() }
        if (typed.isEmpty() || macPublicKey.isEmpty()) return Result.Rejected("PAIRING_REQUIRED")
        val now = SystemClock.elapsedRealtime()
        if (now - lastFailedCodeAt < FAILED_CODE_COOLDOWN_MS) return Result.Rejected("RATE_LIMITED")
        if (!MessageDigest.isEqual(typed.toByteArray(), pairingCode.toByteArray())) {
            lastFailedCodeAt = now
            return Result.Rejected("INVALID_CODE")
        }

        val (secret, phonePublicKey) = try {
            deriveSecret(macPublicKey)
        } catch (_: Exception) {
            return Result.Rejected("PAIRING_REQUIRED")
        }
        prefs.edit().putString(MAC_PREFIX + deviceId, Base64.encodeToString(secret, Base64.NO_WRAP)).commit()
        rotateCode()
        return Result.Accepted(secret, phonePublicKey)
    }

    /** ECDH(P-256) with the Mac's ephemeral key (DER SubjectPublicKeyInfo, base64). */
    private fun deriveSecret(macPublicKeyB64: String): Pair<ByteArray, String> {
        val macKey = KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(Base64.decode(macPublicKeyB64, Base64.NO_WRAP)))
        val ephemeral = KeyPairGenerator.getInstance("EC")
            .apply { initialize(ECGenParameterSpec("secp256r1"), random) }
            .generateKeyPair()
        val shared = KeyAgreement.getInstance("ECDH").run {
            init(ephemeral.private)
            doPhase(macKey, true)
            generateSecret()
        }
        val secret = hmac(shared, "linkmymac-pairing-v1".toByteArray(Charsets.UTF_8))
        return secret to Base64.encodeToString(ephemeral.public.encoded, Base64.NO_WRAP)
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun newCode(): String =
        String(CharArray(CODE_LENGTH) { CODE_ALPHABET[random.nextInt(CODE_ALPHABET.length)] })

    private fun randomBytes(n: Int) = ByteArray(n).also { random.nextBytes(it) }

    private fun hmac(key: ByteArray, message: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(message)
        }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}
