// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64

class DeviceTrustChallengeSignerTest {
    @Test
    fun signsNonceWithMatchingClientAuthCertificate() {
        val nonce = "test nonce".toByteArray()
        val signer =
            DeviceTrustChallengeSigner(
                keyStore =
                    FakeDeviceTrustKeyStore(
                        certificates = mapOf(SUBJECT_CN to listOf(leafCertificate())),
                        privateKeys = mapOf(SUBJECT_CN to leafPrivateKey()),
                    ),
                clock = FIXTURE_VALID_CLOCK,
                log = NoopDeviceTrustLogSink,
            )

        val responses =
            signer.sign(
                nonce = nonce,
                subjectCommonName = SUBJECT_CN,
                candidateAliases = listOf(SUBJECT_CN),
            )

        assertEquals(1, responses.size)

        val response = responses.single()
        val certificate = parseCertificate(Base64.getDecoder().decode(response.cert))
        val verifier = Signature.getInstance("SHA256withRSA")

        verifier.initVerify(certificate.publicKey)
        verifier.update(nonce)

        assertTrue(verifier.verify(Base64.getDecoder().decode(response.signedChallenge)))
    }

    @Test
    fun skipsCertificateWithWrongSubjectCommonName() {
        val signer =
            DeviceTrustChallengeSigner(
                keyStore =
                    FakeDeviceTrustKeyStore(
                        certificates = mapOf(SUBJECT_CN to listOf(leafCertificate())),
                        privateKeys = mapOf(SUBJECT_CN to leafPrivateKey()),
                    ),
                clock = FIXTURE_VALID_CLOCK,
                log = NoopDeviceTrustLogSink,
            )

        val responses =
            signer.sign(
                nonce = "test nonce".toByteArray(),
                subjectCommonName = "wrong.example",
                candidateAliases = listOf(SUBJECT_CN),
            )

        assertTrue(responses.isEmpty())
    }

    @Test
    fun skipsCertificateOutsideValidityWindow() {
        val signer =
            DeviceTrustChallengeSigner(
                keyStore =
                    FakeDeviceTrustKeyStore(
                        certificates = mapOf(SUBJECT_CN to listOf(leafCertificate())),
                        privateKeys = mapOf(SUBJECT_CN to leafPrivateKey()),
                    ),
                clock = Clock.fixed(Instant.parse("2026-04-01T00:00:00Z"), ZoneOffset.UTC),
                log = NoopDeviceTrustLogSink,
            )

        val responses =
            signer.sign(
                nonce = "test nonce".toByteArray(),
                subjectCommonName = SUBJECT_CN,
                candidateAliases = listOf(SUBJECT_CN),
            )

        assertTrue(responses.isEmpty())
    }

    @Test
    fun skipsCertificateWithoutPrivateKeyAccess() {
        val signer =
            DeviceTrustChallengeSigner(
                keyStore =
                    FakeDeviceTrustKeyStore(
                        certificates = mapOf(SUBJECT_CN to listOf(leafCertificate())),
                        privateKeys = emptyMap(),
                    ),
                clock = FIXTURE_VALID_CLOCK,
                log = NoopDeviceTrustLogSink,
            )

        val responses =
            signer.sign(
                nonce = "test nonce".toByteArray(),
                subjectCommonName = SUBJECT_CN,
                candidateAliases = listOf(SUBJECT_CN),
            )

        assertTrue(responses.isEmpty())
    }

    @Test
    fun returnsNoResponsesForInvalidNonceBase64() {
        val signer =
            DeviceTrustChallengeSigner(
                keyStore =
                    FakeDeviceTrustKeyStore(
                        certificates = mapOf(SUBJECT_CN to listOf(leafCertificate())),
                        privateKeys = mapOf(SUBJECT_CN to leafPrivateKey()),
                    ),
                clock = FIXTURE_VALID_CLOCK,
                log = NoopDeviceTrustLogSink,
            )

        val responses =
            signer.signBase64Nonce(
                nonceBase64 = "not base64",
                subjectCommonName = SUBJECT_CN,
                candidateAliases = listOf(SUBJECT_CN),
            )

        assertTrue(responses.isEmpty())
    }

    @Test
    fun returnsNoResponsesForWrongNonceLength() {
        val signer =
            DeviceTrustChallengeSigner(
                keyStore =
                    FakeDeviceTrustKeyStore(
                        certificates = mapOf(SUBJECT_CN to listOf(leafCertificate())),
                        privateKeys = mapOf(SUBJECT_CN to leafPrivateKey()),
                    ),
                clock = FIXTURE_VALID_CLOCK,
                log = NoopDeviceTrustLogSink,
            )

        val responses =
            signer.signBase64Nonce(
                nonceBase64 = Base64.getEncoder().encodeToString("too short".toByteArray()),
                subjectCommonName = SUBJECT_CN,
                candidateAliases = listOf(SUBJECT_CN),
            )

        assertTrue(responses.isEmpty())
    }

    private class FakeDeviceTrustKeyStore(
        private val certificates: Map<String, List<X509Certificate>>,
        private val privateKeys: Map<String, PrivateKey>,
    ) : DeviceTrustKeyStore {
        override fun certificateChain(alias: String): List<X509Certificate> =
            certificates[alias].orEmpty()

        override fun privateKey(alias: String): PrivateKey? = privateKeys[alias]
    }

    private object NoopDeviceTrustLogSink : DeviceTrustLogSink {
        override fun debug(message: String) = Unit

        override fun warning(
            message: String,
            throwable: Throwable?,
        ) = Unit
    }

    private companion object {
        private const val SUBJECT_CN = "dev.firezone.device-trust"

        private val FIXTURE_VALID_CLOCK: Clock =
            Clock.fixed(Instant.parse("2026-04-23T00:00:00Z"), ZoneOffset.UTC)

        private fun leafCertificate(): X509Certificate =
            parseCertificate(fixtureFile("leaf.der").readBytes())

        private fun leafPrivateKey(): PrivateKey {
            val pem = fixtureFile("leaf.key").readText()
            val der =
                pem
                    .replace("-----BEGIN PRIVATE KEY-----", "")
                    .replace("-----END PRIVATE KEY-----", "")
                    .replace("\\s".toRegex(), "")
                    .let { Base64.getDecoder().decode(it) }

            return KeyFactory
                .getInstance("RSA")
                .generatePrivate(PKCS8EncodedKeySpec(der))
        }

        private fun parseCertificate(der: ByteArray): X509Certificate =
            CertificateFactory
                .getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(der)) as X509Certificate

        private fun fixtureFile(name: String): File {
            val path = "elixir/test/support/fixtures/device_trust_challenges/$name"
            val candidates =
                listOf(
                    File(path),
                    File("../$path"),
                    File("../../$path"),
                    File("../../../$path"),
                    File("../../../../$path"),
                )

            return candidates.firstOrNull { it.isFile }
                ?: error("Could not find fixture $name from ${File(".").absolutePath}")
        }
    }
}
