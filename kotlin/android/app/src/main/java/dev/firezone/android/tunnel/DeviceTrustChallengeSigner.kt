// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.content.Context
import android.security.KeyChain
import android.security.KeyChainException
import dev.firezone.android.core.Log
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.CertificateParsingException
import java.security.cert.X509Certificate
import java.time.Clock
import java.util.Base64
import java.util.Date
import javax.security.auth.x500.X500Principal

internal const val DEFAULT_DEVICE_TRUST_CERTIFICATE_ALIAS = "dev.firezone.device-trust"

internal fun deviceTrustCandidateAliases(
    managedAlias: String?,
    cachedAlias: String?,
): List<String> =
    listOfNotNull(
        cachedAlias?.trim()?.takeIf { it.isNotEmpty() },
        managedAlias?.trim()?.takeIf { it.isNotEmpty() },
        // Intune can silently grant this conventional alias for corporate-owned Android devices.
        DEFAULT_DEVICE_TRUST_CERTIFICATE_ALIAS,
    ).distinct()

internal fun preferredDeviceTrustCertificateAlias(
    managedAlias: String?,
    cachedAlias: String?,
): String? = deviceTrustCandidateAliases(managedAlias, cachedAlias).firstOrNull()

internal data class InspectedDeviceTrustCertificate(
    val alias: String,
    val summary: X509ClientAuthCertificateSummary,
    val hasPrivateKeyAccess: Boolean,
    val isCurrentlyValid: Boolean,
) {
    val isUsable: Boolean
        get() = summary.hasClientAuthExtendedKeyUsage && hasPrivateKeyAccess && isCurrentlyValid

    fun isUsableForSubject(subjectCommonName: String): Boolean =
        isUsable && summary.commonName == subjectCommonName
}

internal fun inspectDeviceTrustCertificate(
    context: Context,
    alias: String,
): InspectedDeviceTrustCertificate? {
    val keyStore = AndroidDeviceTrustKeyStore(context)
    val leaf = keyStore.certificateChain(alias).firstOrNull() ?: return null
    val summary = X509ClientAuthCertificateSummary.from(leaf)
    val hasPrivateKeyAccess = keyStore.privateKey(alias) != null
    val isCurrentlyValid = summary.isValidAt(Date())

    return InspectedDeviceTrustCertificate(
        alias = alias,
        summary = summary,
        hasPrivateKeyAccess = hasPrivateKeyAccess,
        isCurrentlyValid = isCurrentlyValid,
    )
}

internal data class DeviceTrustChallengeResponse(
    val signedChallenge: String,
    val cert: String,
)

internal interface DeviceTrustKeyStore {
    fun certificateChain(alias: String): List<X509Certificate>

    fun privateKey(alias: String): PrivateKey?
}

internal class AndroidDeviceTrustKeyStore(
    context: Context,
) : DeviceTrustKeyStore {
    private val applicationContext = context.applicationContext

    override fun certificateChain(alias: String): List<X509Certificate> =
        try {
            KeyChain.getCertificateChain(applicationContext, alias)
                ?.filterIsInstance<X509Certificate>()
                .orEmpty()
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            emptyList()
        } catch (e: KeyChainException) {
            emptyList()
        }

    override fun privateKey(alias: String): PrivateKey? =
        try {
            KeyChain.getPrivateKey(applicationContext, alias)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            null
        } catch (e: KeyChainException) {
            null
        }
}

internal interface DeviceTrustLogSink {
    fun debug(message: String)

    fun warning(
        message: String,
        throwable: Throwable? = null,
    )
}

private object AndroidDeviceTrustLogSink : DeviceTrustLogSink {
    override fun debug(message: String) {
        Log.d(TAG, message)
    }

    override fun warning(
        message: String,
        throwable: Throwable?,
    ) {
        if (throwable == null) {
            Log.w(TAG, message)
        } else {
            Log.w(TAG, message, throwable)
        }
    }

    private const val TAG = "DeviceTrust"
}

internal class DeviceTrustChallengeSigner(
    private val keyStore: DeviceTrustKeyStore,
    private val clock: Clock = Clock.systemUTC(),
    private val log: DeviceTrustLogSink = AndroidDeviceTrustLogSink,
) {
    fun signBase64Nonce(
        nonceBase64: String,
        subjectCommonName: String,
        candidateAliases: List<String>,
    ): List<DeviceTrustChallengeResponse> {
        val nonce =
            try {
                Base64.getDecoder().decode(nonceBase64)
            } catch (e: IllegalArgumentException) {
                log.warning("Device trust signer: nonce is not valid base64", e)
                return emptyList()
            }

        // The Portal challenge is exactly 32 bytes. Refusing any other length keeps
        // the signed payload format fixed and matches the Swift implementation.
        if (nonce.size != NONCE_BYTE_COUNT) {
            log.warning(
                "Device trust signer: invalid nonce length expected=$NONCE_BYTE_COUNT " +
                    "actual=${nonce.size}",
            )
            return emptyList()
        }

        return sign(
            nonce = nonce,
            subjectCommonName = subjectCommonName,
            candidateAliases = candidateAliases,
        )
    }

    fun sign(
        nonce: ByteArray,
        subjectCommonName: String,
        candidateAliases: List<String>,
    ): List<DeviceTrustChallengeResponse> {
        val aliases = candidateAliases.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        log.debug(
            "Device trust signer: checking ${aliases.size} Android KeyChain alias(es) " +
                "for subject CN $subjectCommonName",
        )

        return aliases.mapNotNull { alias ->
            val chain = keyStore.certificateChain(alias)
            val leaf = chain.firstOrNull()

            if (leaf == null) {
                log.debug("Device trust signer: skipping alias=$alias reason=no_certificate_chain")
                return@mapNotNull null
            }

            val summary = X509ClientAuthCertificateSummary.from(leaf)

            if (summary.commonName != subjectCommonName) {
                log.debug(
                    "Device trust signer: skipping alias=$alias cert_sha256=${summary.sha256} " +
                        "subject_cn=${summary.commonName} reason=subject_cn_mismatch",
                )
                return@mapNotNull null
            }

            if (!summary.isValidAt(Date.from(clock.instant()))) {
                log.debug(
                    "Device trust signer: skipping alias=$alias cert_sha256=${summary.sha256} " +
                        "reason=certificate_not_valid not_before=${summary.notBefore} " +
                        "not_after=${summary.notAfter}",
                )
                return@mapNotNull null
            }

            if (!summary.hasClientAuthExtendedKeyUsage) {
                log.debug(
                    "Device trust signer: skipping alias=$alias cert_sha256=${summary.sha256} " +
                        "reason=missing_client_auth_eku eku=${summary.extendedKeyUsage}",
                )
                return@mapNotNull null
            }

            val privateKey = keyStore.privateKey(alias)
            if (privateKey == null) {
                log.debug(
                    "Device trust signer: skipping alias=$alias cert_sha256=${summary.sha256} " +
                        "reason=no_private_key_access",
                )
                return@mapNotNull null
            }

            val algorithm = signatureAlgorithm(privateKey, leaf)
            if (algorithm == null) {
                log.debug(
                    "Device trust signer: skipping alias=$alias cert_sha256=${summary.sha256} " +
                        "reason=unsupported_key_algorithm private_key_algorithm=${privateKey.algorithm} " +
                        "public_key_algorithm=${leaf.publicKey.algorithm}",
                )
                return@mapNotNull null
            }

            try {
                val signature = Signature.getInstance(algorithm)

                // This is the cryptographic proof: only an app with access to the private key
                // corresponding to the leaf certificate can produce a signature the Portal can
                // verify with the public key embedded in the returned certificate.
                signature.initSign(privateKey)
                signature.update(nonce)

                log.debug(
                    "Device trust signer: selected alias=$alias cert_sha256=${summary.sha256} " +
                        "subject_cn=${summary.commonName} algorithm=$algorithm",
                )

                DeviceTrustChallengeResponse(
                    signedChallenge = Base64.getEncoder().encodeToString(signature.sign()),
                    cert = Base64.getEncoder().encodeToString(leaf.encoded),
                )
            } catch (e: Exception) {
                log.warning(
                    "Device trust signer: skipping alias=$alias cert_sha256=${summary.sha256} " +
                        "reason=signature_failed",
                    e,
                )
                null
            }
        }
    }

    private fun signatureAlgorithm(
        privateKey: PrivateKey,
        certificate: X509Certificate,
    ): String? {
        val privateKeyAlgorithm = privateKey.algorithm.uppercase()
        val publicKeyAlgorithm = certificate.publicKey.algorithm.uppercase()

        return when {
            privateKeyAlgorithm == "RSA" && publicKeyAlgorithm == "RSA" -> "SHA256withRSA"
            privateKeyAlgorithm == "EC" && publicKeyAlgorithm == "EC" -> "SHA256withECDSA"
            privateKeyAlgorithm == "ECDSA" &&
                publicKeyAlgorithm == "EC" -> "SHA256withECDSA"

            else -> null
        }
    }

    private companion object {
        private const val NONCE_BYTE_COUNT = 32
    }
}

internal data class X509ClientAuthCertificateSummary(
    val commonName: String?,
    val issuerCommonName: String?,
    val extendedKeyUsage: List<String>,
    val notBefore: Date,
    val notAfter: Date,
    val sha256: String,
) {
    val hasClientAuthExtendedKeyUsage: Boolean
        get() = extendedKeyUsage.contains(CLIENT_AUTH_EXTENDED_KEY_USAGE)

    fun isValidAt(date: Date): Boolean = !date.before(notBefore) && !date.after(notAfter)

    companion object {
        // RFC 5280 EKU id-kp-clientAuth. We require this so that a random signing-capable
        // certificate cannot be reused as a Firezone device-trust credential.
        private const val CLIENT_AUTH_EXTENDED_KEY_USAGE = "1.3.6.1.5.5.7.3.2"

        fun from(certificate: X509Certificate): X509ClientAuthCertificateSummary =
            X509ClientAuthCertificateSummary(
                // The CN is only a selector. Trust comes from validating the certificate chain
                // server-side and verifying the signature over the nonce.
                commonName = certificate.subjectCommonName(),
                issuerCommonName = certificate.issuerCommonName(),
                extendedKeyUsage = certificate.safeExtendedKeyUsage(),
                notBefore = certificate.notBefore,
                notAfter = certificate.notAfter,
                sha256 = certificate.sha256Hex(),
            )
    }
}

private fun X509Certificate.safeExtendedKeyUsage(): List<String> =
    try {
        extendedKeyUsage.orEmpty()
    } catch (e: CertificateParsingException) {
        emptyList()
    }

private fun X509Certificate.sha256Hex(): String =
    MessageDigest
        .getInstance("SHA-256")
        .digest(encoded)
        .joinToString("") { "%02x".format(it) }

private fun X509Certificate.subjectCommonName(): String? =
    subjectX500Principal
        .getName(X500Principal.RFC2253)
        .rfc2253AttributeValue("CN")

private fun X509Certificate.issuerCommonName(): String? =
    issuerX500Principal
        .getName(X500Principal.RFC2253)
        .rfc2253AttributeValue("CN")

private fun String.rfc2253AttributeValue(attributeName: String): String? =
    splitUnescaped(',')
        .mapNotNull { rdn ->
            val parts = rdn.splitUnescaped('=', limit = 2)
            if (parts.size != 2) {
                null
            } else {
                parts[0].trim() to parts[1].trim().unescapeRfc2253()
            }
        }.firstOrNull { (name, _) -> name.equals(attributeName, ignoreCase = true) }
        ?.second

private fun String.splitUnescaped(
    delimiter: Char,
    limit: Int = Int.MAX_VALUE,
): List<String> {
    val parts = mutableListOf<String>()
    val current = StringBuilder()
    var escaped = false

    for (char in this) {
        when {
            escaped -> {
                current.append('\\')
                current.append(char)
                escaped = false
            }
            char == '\\' -> escaped = true
            char == delimiter && parts.size < limit - 1 -> {
                parts.add(current.toString())
                current.clear()
            }
            else -> current.append(char)
        }
    }

    if (escaped) {
        current.append('\\')
    }

    parts.add(current.toString())
    return parts
}

private fun String.unescapeRfc2253(): String {
    val result = StringBuilder()
    var escaped = false

    for (char in this) {
        when {
            escaped -> {
                result.append(char)
                escaped = false
            }
            char == '\\' -> escaped = true
            else -> result.append(char)
        }
    }

    if (escaped) {
        result.append('\\')
    }

    return result.toString()
}
