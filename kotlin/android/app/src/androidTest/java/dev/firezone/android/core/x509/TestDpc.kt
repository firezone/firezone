// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.x509

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Drives the test Device Policy Controller in `dpc/`, which owns the device in the `managed`
 * emulator suite.
 *
 * Installing a key pair is an owner-only API, which is the one thing standing between a test and
 * the KeyChain states it wants to pin. The DPC takes its instructions as ordered broadcasts and
 * reports back through the broadcast's result.
 */
object TestDpc {
    /** Installs [p12] under [alias], granting the app under test access only when asked. */
    fun installKeyPair(
        alias: String,
        p12: ByteArray,
        password: String,
        grantToFirezone: Boolean,
    ) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext

        val intent =
            Intent("dev.firezone.dpc.INSTALL_KEY_PAIR")
                .setClassName(DPC_PACKAGE, "$DPC_PACKAGE.ProvisionReceiver")
                // A freshly installed DPC has never run, and stopped packages receive nothing.
                .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
                .putExtra("alias", alias)
                .putExtra("password", password)
                .putExtra("p12", Base64.encodeToString(p12, Base64.NO_WRAP))
                .apply {
                    if (grantToFirezone) {
                        putExtra("grantTo", context.packageName)
                    }
                }

        val answered = CountDownLatch(1)
        var answerCode = NO_ANSWER
        var answer: String? = null

        context.sendOrderedBroadcast(
            intent,
            null,
            object : BroadcastReceiver() {
                override fun onReceive(
                    context: Context,
                    intent: Intent,
                ) {
                    answerCode = resultCode
                    answer = resultData
                    answered.countDown()
                }
            },
            null,
            NO_ANSWER,
            null,
            null,
        )

        if (!answered.await(20, TimeUnit.SECONDS)) {
            throw AssertionError("The DPC did not answer the install broadcast for '$alias'")
        }

        when (answerCode) {
            0 -> Unit

            // Nobody touched the result, so the broadcast found no receiver.
            NO_ANSWER -> throw AssertionError(
                "$DPC_PACKAGE is not installed; provision the device first: " +
                    "mise run //kotlin/android:managed-device:provision",
            )

            else -> throw AssertionError("The DPC refused to install '$alias': $answer")
        }
    }

    private const val DPC_PACKAGE = "dev.firezone.dpc"
    private const val NO_ANSWER = -1
}
