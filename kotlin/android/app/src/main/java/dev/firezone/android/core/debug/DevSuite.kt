package dev.firezone.android.core.debug

import android.content.Intent
import androidx.fragment.app.FragmentActivity
import dev.firezone.android.BuildConfig
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.core.presentation.MainActivity
import kotlinx.coroutines.flow.collect
import javax.inject.Inject

internal class DevSuite @Inject constructor(
    private val repository: PreferenceRepository
) {

    suspend fun signInWithDebugUser(activity: FragmentActivity) {
        repository.saveAccountId("firezone").collect()
        repository.saveToken(BuildConfig.TOKEN).collect()

        val intent = Intent(activity, MainActivity::class.java)
        activity.startActivity(intent)
        activity.finish()
    }
}
