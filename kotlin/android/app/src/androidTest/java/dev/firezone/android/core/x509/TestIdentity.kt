// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.ExtendedKeyUsage
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.x509.KeyPurposeId
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.cert.X509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Date
import java.util.concurrent.TimeUnit

/**
 * A client identity minted for one test: a CA-signed leaf carrying [claims], and its key.
 *
 * The platform offers no way to build a certificate, hence BouncyCastle. The claims are the
 * `firezone://` subject alternative names as `//:x509:gen-certificate` would write them, so what
 * the real parser reads out of a minted leaf is what it would read out of an issued one.
 */
class TestIdentity(
    val chain: List<X509Certificate>,
    val privateKey: PrivateKey,
) {
    /** The identity packed the way an administrator would hand it to a DPC. */
    fun pkcs12(
        alias: String,
        password: String,
    ): ByteArray {
        val keyStore = KeyStore.getInstance("PKCS12")
        keyStore.load(null, null)
        keyStore.setKeyEntry(alias, privateKey, password.toCharArray(), chain.toTypedArray())

        return ByteArrayOutputStream().use { out ->
            keyStore.store(out, password.toCharArray())
            out.toByteArray()
        }
    }
}

/** Mints a client identity whose leaf claims exactly [claims], e.g. `firezone://serial/EMU-1`. */
fun testIdentity(vararg claims: String): TestIdentity {
    val caKeyPair = rsaKeyPair()
    val caName = X500Name("O=Firezone,CN=Firezone Test CA")
    val notBefore = Date(System.currentTimeMillis() - TimeUnit.HOURS.toMillis(1))
    val notAfter = Date(System.currentTimeMillis() + TimeUnit.DAYS.toMillis(365))

    val ca =
        JcaX509v3CertificateBuilder(caName, BigInteger.ONE, notBefore, notAfter, caName, caKeyPair.public)
            .addExtension(Extension.basicConstraints, true, BasicConstraints(true))
            .toCertificate(caKeyPair.private)

    val leafKeyPair = rsaKeyPair()
    val subjectAlternativeNames =
        GeneralNames(
            claims
                .map { claim -> GeneralName(GeneralName.uniformResourceIdentifier, claim) }
                .toTypedArray(),
        )

    val leaf =
        JcaX509v3CertificateBuilder(
            caName,
            BigInteger.valueOf(2),
            notBefore,
            notAfter,
            X500Name("O=Firezone,CN=dev.firezone.device-trust"),
            leafKeyPair.public,
        ).addExtension(Extension.basicConstraints, true, BasicConstraints(false))
            .addExtension(Extension.keyUsage, true, KeyUsage(KeyUsage.digitalSignature or KeyUsage.keyEncipherment))
            .addExtension(Extension.extendedKeyUsage, false, ExtendedKeyUsage(KeyPurposeId.id_kp_clientAuth))
            .addExtension(Extension.subjectAlternativeName, false, subjectAlternativeNames)
            .toCertificate(caKeyPair.private)

    return TestIdentity(chain = listOf(leaf, ca), privateKey = leafKeyPair.private)
}

private fun rsaKeyPair(): KeyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()

private fun X509v3CertificateBuilder.toCertificate(issuerKey: PrivateKey): X509Certificate =
    JcaX509CertificateConverter().getCertificate(build(JcaContentSignerBuilder("SHA256withRSA").build(issuerKey)))
