// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.device_trust.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.security.KeyChain
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import dev.firezone.android.R
import dev.firezone.android.core.Log
import dev.firezone.android.tunnel.inspectDeviceTrustCertificate
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal object DeviceTrustCertificatePromptCoordinator {
    private const val TAG = "DeviceTrust"
    private const val SELECTION_TIMEOUT_MS = 120_000L

    private val lock = Any()
    private var pendingSelection: CompletableDeferred<String?>? = null

    suspend fun promptForAlias(
        context: Context,
        subjectCommonName: String,
        preferredAlias: String?,
    ): String? {
        val deferred = CompletableDeferred<String?>()

        synchronized(lock) {
            pendingSelection?.complete(null)
            pendingSelection = deferred
        }

        return try {
            context.startActivity(
                DeviceTrustCertificatePromptActivity.intent(
                    context = context,
                    subjectCommonName = subjectCommonName,
                    preferredAlias = preferredAlias,
                ),
            )

            withTimeoutOrNull(SELECTION_TIMEOUT_MS) { deferred.await() }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to launch device trust certificate prompt", e)
            null
        } finally {
            synchronized(lock) {
                if (pendingSelection === deferred) {
                    pendingSelection = null
                }
            }
        }
    }

    fun completeSelection(alias: String?) {
        synchronized(lock) {
            pendingSelection?.complete(alias)
        }
    }
}

internal class DeviceTrustCertificatePromptActivity : AppCompatActivity() {
    private var completed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = getString(R.string.device_trust_prompt_title)
        launchChooser()
    }

    override fun onDestroy() {
        if (isFinishing && !completed) {
            DeviceTrustCertificatePromptCoordinator.completeSelection(null)
        }

        super.onDestroy()
    }

    private fun launchChooser() {
        KeyChain.choosePrivateKeyAlias(
            this,
            { alias ->
                runOnUiThread {
                    lifecycleScope.launch {
                        handleSelection(alias)
                    }
                }
            },
            arrayOf("RSA", "EC"),
            null,
            null,
            intent.getStringExtra(EXTRA_PREFERRED_ALIAS),
        )
    }

    private suspend fun handleSelection(alias: String?) {
        if (alias.isNullOrBlank()) {
            completeAndFinish(null)
            return
        }

        val subjectCommonName = intent.getStringExtra(EXTRA_SUBJECT_COMMON_NAME).orEmpty()
        val inspection =
            withContext(Dispatchers.IO) {
                inspectDeviceTrustCertificate(this@DeviceTrustCertificatePromptActivity, alias)
            }

        if (inspection == null || !inspection.isUsableForSubject(subjectCommonName)) {
            showInvalidSelectionDialog()
            return
        }

        completeAndFinish(alias)
    }

    private fun showInvalidSelectionDialog() {
        AlertDialog
            .Builder(this)
            .setTitle(R.string.device_trust_prompt_title)
            .setMessage(R.string.device_trust_invalid_selection)
            .setPositiveButton(R.string.device_trust_retry_selection) { _, _ ->
                launchChooser()
            }
            .setNegativeButton(android.R.string.cancel) { _, _ ->
                completeAndFinish(null)
            }
            .setOnCancelListener {
                completeAndFinish(null)
            }
            .show()
    }

    private fun completeAndFinish(alias: String?) {
        if (completed) {
            return
        }

        completed = true
        DeviceTrustCertificatePromptCoordinator.completeSelection(alias)
        finish()
    }

    companion object {
        private const val EXTRA_SUBJECT_COMMON_NAME = "subject_common_name"
        private const val EXTRA_PREFERRED_ALIAS = "preferred_alias"

        fun intent(
            context: Context,
            subjectCommonName: String,
            preferredAlias: String?,
        ): Intent =
            Intent(context, DeviceTrustCertificatePromptActivity::class.java).apply {
                putExtra(EXTRA_SUBJECT_COMMON_NAME, subjectCommonName)
                putExtra(EXTRA_PREFERRED_ALIAS, preferredAlias)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
            }
    }
}
