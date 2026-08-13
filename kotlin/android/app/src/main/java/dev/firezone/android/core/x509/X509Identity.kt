// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.app.admin.DevicePolicyManager
import android.content.Context
import android.os.Build
import android.os.UserManager
import android.security.KeyChain
import dagger.hilt.android.qualifiers.ApplicationContext
import dev.firezone.android.core.Log
import uniffi.connlib.CallbackException
import uniffi.connlib.ClientTlsIdentity
import uniffi.connlib.TlsSignatureScheme
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PSSParameterSpec
import java.time.format.DateTimeFormatter
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

data class X509DetailField(
    val label: String,
    val value: String,
)

data class X509DetailSection(
    val title: String,
    val fields: List<X509DetailField>,
)

data class X509IdentityDetails(
    val summary: String,
    val sections: List<X509DetailSection>,
)

data class LoadedX509Identity(
    val clientTlsIdentity: ClientTlsIdentity,
    val mdmDeviceId: String?,
)

internal object NoClientTlsIdentity : ClientTlsIdentity {
    override fun certificateChain(): List<ByteArray> = emptyList()

    override fun supportedSignatureSchemes(): List<TlsSignatureScheme> = emptyList()

    override fun sign(
        scheme: TlsSignatureScheme,
        message: ByteArray,
    ): ByteArray = throw CallbackException.Failed("No X.509 client identity is configured.")
}

class X509IdentityException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * Uses an identity from Android's system KeyChain without exporting its private-key bytes.
 *
 * KeyChain calls can block on a system service, so callers must invoke [clientTlsIdentity] and
 * [details] from a worker thread.
 */
@Singleton
class X509Identity
    @Inject
    constructor(
        @param:ApplicationContext private val context: Context,
    ) {
        fun clientTlsIdentity(alias: String?): LoadedX509Identity? {
            if (alias == null) {
                Log.i(TAG, "No Android KeyChain alias is configured for mutual TLS")
                return null
            }

            val chain = loadCertificateChain(alias)
            val leaf = chain.first()
            validateLeafCommonName(leaf)
            val privateKey = loadPrivateKey(alias)
            val schemes = supportedSignatureSchemes(leaf.publicKey)
            val mdmDeviceId = mdmDeviceId(leaf)

            Log.i(
                TAG,
                "Loaded mutual-TLS client identity " +
                    "(alias=$alias, certificates=${chain.size}, notBefore=${leaf.notBefore.toInstant()}, " +
                    "leafFingerprint=${sha256Hex(leaf.encoded)}, mdmDeviceId=${mdmDeviceId ?: "Unavailable"})",
            )

            return LoadedX509Identity(
                clientTlsIdentity =
                    AndroidClientTlsIdentity(
                        alias = alias,
                        privateKey = privateKey,
                        certificateChain = chain,
                        schemes = schemes,
                    ),
                mdmDeviceId = mdmDeviceId,
            )
        }

        fun details(
            alias: String?,
            isManaged: Boolean,
        ): X509IdentityDetails {
            val configurationFields =
                mutableListOf(
                    X509DetailField("Android profile", profileDescription()),
                    X509DetailField(
                        "Alias source",
                        if (isManaged) "Managed configuration" else "User selection",
                    ),
                    X509DetailField("KeyChain alias", alias ?: "Not configured"),
                )

            if (alias == null) {
                return X509IdentityDetails(
                    summary = "No X.509 device identity is configured.",
                    sections = listOf(X509DetailSection("Configuration", configurationFields)),
                )
            }

            val chain = loadCertificateChain(alias)
            validateLeafCommonName(chain.first())
            val privateKey = loadPrivateKey(alias)
            configurationFields += X509DetailField("Key access", "Available")
            configurationFields += X509DetailField("Certificate count", chain.size.toString())

            val sections =
                mutableListOf(
                    X509DetailSection("Configuration", configurationFields),
                    X509DetailSection(
                        "Private Key",
                        listOf(
                            X509DetailField("Algorithm", privateKey.algorithm),
                            X509DetailField("Provider class", privateKey.javaClass.name),
                            X509DetailField("Encoded format", privateKey.format ?: "Non-exportable"),
                            X509DetailField(
                                "Private key export",
                                "Not attempted; mutual-TLS signing occurs through the KeyChain key handle.",
                            ),
                        ),
                    ),
                )

            sections +=
                chain.mapIndexed { index, certificate ->
                    certificateSection(
                        certificate = certificate,
                        title = if (index == 0) "Leaf Certificate" else "Certificate ${index + 1}",
                    )
                }

            return X509IdentityDetails(
                summary = "The configured X.509 identity is available for mutual TLS.",
                sections = sections,
            )
        }

        fun isSupportedProfile(): Boolean {
            val profileState = profileState()
            return isSupportedProfile(
                isManagedProfile = profileState.isManagedProfile,
                hasDeviceOwner = profileState.hasDeviceOwner,
            )
        }

        private fun loadCertificateChain(alias: String): List<X509Certificate> {
            val chain =
                try {
                    KeyChain.getCertificateChain(context, alias)
                } catch (exception: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw X509IdentityException("Reading the X.509 certificate was interrupted.", exception)
                } catch (exception: Exception) {
                    throw X509IdentityException(
                        "The X.509 certificate chain for alias '$alias' could not be read.",
                        exception,
                    )
                }

            if (chain.isNullOrEmpty()) {
                throw X509IdentityException(
                    "The X.509 certificate for alias '$alias' is missing or Firezone has not been granted access to it.",
                )
            }

            return chain.toList()
        }

        private fun loadPrivateKey(alias: String): PrivateKey {
            val privateKey =
                try {
                    KeyChain.getPrivateKey(context, alias)
                } catch (exception: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw X509IdentityException("Reading the X.509 private key was interrupted.", exception)
                } catch (exception: Exception) {
                    throw X509IdentityException(
                        "The X.509 private key for alias '$alias' could not be opened.",
                        exception,
                    )
                }

            return privateKey
                ?: throw X509IdentityException(
                    "The X.509 private key for alias '$alias' is missing or Firezone has not been granted access to it.",
                )
        }

        private fun validateLeafCommonName(certificate: X509Certificate) {
            val commonName = commonName(certificate)
            if (commonName != EXPECTED_SUBJECT_COMMON_NAME) {
                throw X509IdentityException(
                    "The selected certificate has subject CN '${commonName ?: "None"}'; " +
                        "Firezone requires '$EXPECTED_SUBJECT_COMMON_NAME'.",
                )
            }
        }

        private fun profileState(): ProfileState {
            val userManager = context.getSystemService(UserManager::class.java)
            val devicePolicyManager = context.getSystemService(DevicePolicyManager::class.java)
            val activeAdmins = runCatching { devicePolicyManager?.activeAdmins.orEmpty() }.getOrDefault(emptyList())
            val hasDeviceOwner =
                activeAdmins.any { admin ->
                    runCatching { devicePolicyManager?.isDeviceOwnerApp(admin.packageName) == true }
                        .getOrDefault(false)
                }
            val hasProfileOwner =
                activeAdmins.any { admin ->
                    runCatching { devicePolicyManager?.isProfileOwnerApp(admin.packageName) == true }
                        .getOrDefault(false)
                }
            val isManagedProfile =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    userManager?.isManagedProfile == true
                } else {
                    hasProfileOwner && !hasDeviceOwner
                }
            val isOrganizationOwned =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    runCatching { devicePolicyManager?.isOrganizationOwnedDeviceWithManagedProfile == true }
                        .getOrDefault(false)
                } else {
                    false
                }

            return ProfileState(
                isManagedProfile = isManagedProfile,
                hasDeviceOwner = hasDeviceOwner,
                isOrganizationOwned = isOrganizationOwned,
            )
        }

        private fun profileDescription(): String =
            profileState().run {
                when {
                    isManagedProfile && isOrganizationOwned -> "Organization-owned work profile"
                    isManagedProfile -> "Personally owned work profile"
                    hasDeviceOwner -> "Corporate-owned fully managed device"
                    isOrganizationOwned -> "Organization-owned personal profile"
                    else -> "Personal profile"
                }
            }

        private data class ProfileState(
            val isManagedProfile: Boolean,
            val hasDeviceOwner: Boolean,
            val isOrganizationOwned: Boolean,
        )

        private class AndroidClientTlsIdentity(
            private val alias: String,
            private val privateKey: PrivateKey,
            private val certificateChain: List<X509Certificate>,
            private val schemes: List<TlsSignatureScheme>,
        ) : ClientTlsIdentity {
            override fun certificateChain(): List<ByteArray> = certificateChain.map { it.encoded }

            override fun supportedSignatureSchemes(): List<TlsSignatureScheme> = schemes

            override fun sign(
                scheme: TlsSignatureScheme,
                message: ByteArray,
            ): ByteArray =
                try {
                    sign(privateKey, scheme, message)
                } catch (exception: Exception) {
                    Log.e(TAG, "Android KeyChain failed to sign the TLS handshake", exception)
                    throw CallbackException.Failed(
                        exception.message ?: "The Android KeyChain failed to sign the TLS handshake.",
                    )
                }

            override fun toString(): String = "AndroidClientTlsIdentity(alias=$alias)"
        }

        private fun certificateSection(
            certificate: X509Certificate,
            title: String,
        ): X509DetailSection =
            X509DetailSection(
                title,
                listOf(
                    X509DetailField("Subject", certificate.subjectX500Principal.name),
                    X509DetailField("Issuer", certificate.issuerX500Principal.name),
                    X509DetailField("Subject alternative names", subjectAlternativeNames(certificate)),
                    X509DetailField("Serial number", certificate.serialNumber.toString(16).uppercase()),
                    X509DetailField("Not valid before", DateTimeFormatter.ISO_INSTANT.format(certificate.notBefore.toInstant())),
                    X509DetailField("Not valid after", DateTimeFormatter.ISO_INSTANT.format(certificate.notAfter.toInstant())),
                    X509DetailField("Public-key algorithm", certificate.publicKey.algorithm),
                    X509DetailField("Certificate signature algorithm", certificate.sigAlgName),
                    X509DetailField("SHA-256 fingerprint", sha256Hex(certificate.encoded)),
                    X509DetailField("DER byte count", certificate.encoded.size.toString()),
                    X509DetailField("PEM", pem(certificate.encoded)),
                ),
            )

        companion object {
            private const val TAG = "X509Identity"
            private const val EXPECTED_SUBJECT_COMMON_NAME = "dev.firezone.device-trust"

            internal fun isSupportedProfile(
                isManagedProfile: Boolean,
                hasDeviceOwner: Boolean,
            ): Boolean = isManagedProfile || hasDeviceOwner

            internal fun supportedSignatureSchemes(publicKey: PublicKey): List<TlsSignatureScheme> =
                when (publicKey) {
                    is RSAPublicKey -> {
                        listOf(
                            TlsSignatureScheme.RSA_PSS_SHA512,
                            TlsSignatureScheme.RSA_PSS_SHA384,
                            TlsSignatureScheme.RSA_PSS_SHA256,
                            TlsSignatureScheme.RSA_PKCS1_SHA512,
                            TlsSignatureScheme.RSA_PKCS1_SHA384,
                            TlsSignatureScheme.RSA_PKCS1_SHA256,
                        )
                    }

                    is ECPublicKey -> {
                        when (publicKey.params.curve.field.fieldSize) {
                            256 -> {
                                listOf(TlsSignatureScheme.ECDSA_NISTP256_SHA256)
                            }

                            384 -> {
                                listOf(TlsSignatureScheme.ECDSA_NISTP384_SHA384)
                            }

                            521 -> {
                                listOf(TlsSignatureScheme.ECDSA_NISTP521_SHA512)
                            }

                            else -> {
                                throw X509IdentityException(
                                    "The X.509 identity uses an unsupported EC curve " +
                                        "(${publicKey.params.curve.field.fieldSize} bits).",
                                )
                            }
                        }
                    }

                    else -> {
                        throw X509IdentityException(
                            "The X.509 identity uses an unsupported private key (${publicKey.algorithm}).",
                        )
                    }
                }

            internal fun signatureAlgorithm(scheme: TlsSignatureScheme): String =
                when (scheme) {
                    TlsSignatureScheme.RSA_PKCS1_SHA256 -> "SHA256withRSA"
                    TlsSignatureScheme.RSA_PKCS1_SHA384 -> "SHA384withRSA"
                    TlsSignatureScheme.RSA_PKCS1_SHA512 -> "SHA512withRSA"
                    TlsSignatureScheme.RSA_PSS_SHA256 -> "SHA256withRSA/PSS"
                    TlsSignatureScheme.RSA_PSS_SHA384 -> "SHA384withRSA/PSS"
                    TlsSignatureScheme.RSA_PSS_SHA512 -> "SHA512withRSA/PSS"
                    TlsSignatureScheme.ECDSA_NISTP256_SHA256 -> "SHA256withECDSA"
                    TlsSignatureScheme.ECDSA_NISTP384_SHA384 -> "SHA384withECDSA"
                    TlsSignatureScheme.ECDSA_NISTP521_SHA512 -> "SHA512withECDSA"
                }

            internal fun sign(
                privateKey: PrivateKey,
                scheme: TlsSignatureScheme,
                message: ByteArray,
            ): ByteArray =
                try {
                    val (signature, parameters) = signature(scheme)
                    signature.run {
                        initSign(privateKey)
                        parameters?.let(::setParameter)
                        update(message)
                        sign()
                    }
                } catch (exception: X509IdentityException) {
                    throw exception
                } catch (exception: Exception) {
                    throw X509IdentityException(
                        "The X.509 identity could not sign the TLS handshake.",
                        exception,
                    )
                }

            private fun signature(scheme: TlsSignatureScheme): ConfiguredSignature {
                val algorithm = signatureAlgorithm(scheme)
                return runCatching {
                    // Android's digest-specific RSA/PSS implementations already fix the
                    // digest, MGF digest, and salt length. Their KeyChain-backed SignatureSpi
                    // deliberately rejects setParameter, so parameters must only be supplied
                    // when using the generic RSASSA-PSS fallback.
                    ConfiguredSignature(Signature.getInstance(algorithm), null)
                }.getOrElse {
                    val parameters = pssParameters(scheme)
                    if (parameters != null) {
                        ConfiguredSignature(Signature.getInstance("RSASSA-PSS"), parameters)
                    } else {
                        throw it
                    }
                }
            }

            private data class ConfiguredSignature(
                val signature: Signature,
                val parameters: PSSParameterSpec?,
            )

            private fun pssParameters(scheme: TlsSignatureScheme): PSSParameterSpec? =
                when (scheme) {
                    TlsSignatureScheme.RSA_PSS_SHA256 -> {
                        PSSParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, 32, 1)
                    }

                    TlsSignatureScheme.RSA_PSS_SHA384 -> {
                        PSSParameterSpec("SHA-384", "MGF1", MGF1ParameterSpec.SHA384, 48, 1)
                    }

                    TlsSignatureScheme.RSA_PSS_SHA512 -> {
                        PSSParameterSpec("SHA-512", "MGF1", MGF1ParameterSpec.SHA512, 64, 1)
                    }

                    else -> {
                        null
                    }
                }

            private fun sha256Hex(data: ByteArray): String =
                MessageDigest
                    .getInstance("SHA-256")
                    .digest(data)
                    .joinToString(":") { byte -> "%02X".format(byte) }

            private fun commonName(certificate: X509Certificate): String? =
                RFC2253_COMMON_NAME
                    .find(certificate.subjectX500Principal.name)
                    ?.groupValues
                    ?.get(1)
                    ?.replace("\\,", ",")
                    ?.replace("\\+", "+")
                    ?.replace("\\=", "=")

            private fun subjectAlternativeNames(certificate: X509Certificate): String =
                try {
                    certificate.subjectAlternativeNames
                        ?.mapNotNull { subjectAlternativeName ->
                            val type = subjectAlternativeName.getOrNull(0) as? Int ?: return@mapNotNull null
                            val value = subjectAlternativeName.getOrNull(1) ?: return@mapNotNull null
                            formatSubjectAlternativeName(type, value)
                        }?.takeIf { it.isNotEmpty() }
                        ?.joinToString("\n")
                        ?: "None"
                } catch (exception: Exception) {
                    "Could not parse (${exception.message ?: exception.javaClass.simpleName})"
                }

            internal fun formatSubjectAlternativeName(
                type: Int,
                value: Any,
            ): String {
                val label =
                    when (type) {
                        0 -> "Other name"
                        1 -> "Email"
                        2 -> "DNS"
                        3 -> "X.400 address"
                        4 -> "Directory name"
                        5 -> "EDI party name"
                        6 -> "URI"
                        7 -> "IP address"
                        8 -> "Registered ID"
                        else -> "Type $type"
                    }
                val renderedValue =
                    if (value is ByteArray) {
                        "DER/Base64 ${Base64.getEncoder().encodeToString(value)}"
                    } else {
                        value.toString()
                    }

                return "$label: $renderedValue"
            }

            internal fun mdmDeviceId(uris: List<String>): String? {
                val filteredUris =
                    uris
                        .flatMap { it.split(COMMA_JOINED_URI_BOUNDARY) }
                        .filterNot { it.startsWith(MICROSOFT_SID_URI_PREFIX, ignoreCase = true) }
                var sawTypedIdentifier = false
                var typedMdmDeviceId: String? = null

                filteredUris.forEach { uri ->
                    val match = FIREZONE_URI.matchEntire(uri) ?: return@forEach
                    val idType = match.groupValues[1].lowercase()
                    val value = match.groupValues[2]
                    if (idType !in KNOWN_IDENTIFIER_TYPES || !validIdentifier(value)) return@forEach

                    sawTypedIdentifier = true
                    if (idType in MDM_IDENTIFIER_TYPES && typedMdmDeviceId == null) {
                        typedMdmDeviceId = normalizeMdmDeviceId(value)
                    }
                }

                if (sawTypedIdentifier) return typedMdmDeviceId

                return filteredUris.firstNotNullOfOrNull { uri ->
                    val value = uri.trim()
                    if (value.length == 36 && runCatching { java.util.UUID.fromString(value) }.isSuccess) {
                        normalizeMdmDeviceId(value)
                    } else {
                        null
                    }
                }
            }

            private fun mdmDeviceId(certificate: X509Certificate): String? =
                runCatching {
                    certificate.subjectAlternativeNames
                        ?.mapNotNull { name ->
                            val type = name.getOrNull(0) as? Int
                            val value = name.getOrNull(1) as? String
                            value?.takeIf { type == 6 }
                        }.orEmpty()
                }.map(::mdmDeviceId)
                    .getOrNull()

            private fun validIdentifier(value: String): Boolean {
                val trimmed = value.trim()
                return trimmed.isNotEmpty() &&
                    trimmed.toByteArray(Charsets.UTF_8).size <= 255 &&
                    trimmed.all { it.code in 0x20..0x7E }
            }

            private fun normalizeMdmDeviceId(value: String): String? {
                val normalized = value.trim().lowercase()
                return normalized.takeIf { validIdentifier(it) && it !in INVALID_IDENTIFIER_SENTINELS }
            }

            private fun pem(data: ByteArray): String {
                val body =
                    Base64
                        .getEncoder()
                        .encodeToString(data)
                        .chunked(64)
                        .joinToString("\n")
                return "-----BEGIN CERTIFICATE-----\n$body\n-----END CERTIFICATE-----"
            }

            private val RFC2253_COMMON_NAME = Regex("(?:^|,)CN=((?:\\\\.|[^,])*)", RegexOption.IGNORE_CASE)
            private val FIREZONE_URI = Regex("firezone://([^/]+)/(.+)", RegexOption.IGNORE_CASE)
            private val COMMA_JOINED_URI_BOUNDARY = Regex(",\\s*(?=[a-zA-Z][a-zA-Z0-9+.\\-]*:)")
            private const val MICROSOFT_SID_URI_PREFIX = "tag:microsoft.com,2022-09-14:sid:"
            private val KNOWN_IDENTIFIER_TYPES =
                setOf(
                    "serial",
                    "apple-serial",
                    "udid",
                    "apple-udid",
                    "smbios-uuid",
                    "intune-id",
                    "entra-id",
                    "ws1-uuid",
                    "jamf-id",
                    "kandji-id",
                )
            private val MDM_IDENTIFIER_TYPES =
                setOf("intune-id", "entra-id", "ws1-uuid", "jamf-id", "kandji-id")
            private val INVALID_IDENTIFIER_SENTINELS =
                setOf(
                    "0",
                    "00000000-0000-0000-0000-000000000000",
                    "ffffffff-ffff-ffff-ffff-ffffffffffff",
                    "03000200-0400-0500-0006-000700080009",
                    "idnotpresentbutsettable",
                )
        }
    }
