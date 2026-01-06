// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.utils

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.Toast

object ClipboardUtils {
    private const val COPIED = "Copied"

    fun copyToClipboard(
        context: Context,
        label: String,
        text: String,
    ) {
        val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager.setPrimaryClip(ClipData.newPlainText(label, text))

        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.S_V2) {
            Toast.makeText(context, COPIED, Toast.LENGTH_SHORT).show()
        }
    }
}
