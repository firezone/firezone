// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.content.Context

internal class DeveloperSettings(
    context: Context,
) {
    private val preferences = context.getSharedPreferences("developer_settings", Context.MODE_PRIVATE)

    var isUnlocked: Boolean
        get() = preferences.getBoolean(UNLOCKED_KEY, false)
        set(value) {
            preferences.edit().putBoolean(UNLOCKED_KEY, value).apply()
        }

    private companion object {
        const val UNLOCKED_KEY = "unlocked"
    }
}
