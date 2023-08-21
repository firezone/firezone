package dev.firezone.android.core.debug

import android.content.Intent
import androidx.fragment.app.FragmentActivity
import dev.firezone.android.core.data.PreferenceRepository
import dev.firezone.android.core.presentation.MainActivity
import kotlinx.coroutines.flow.collect
import javax.inject.Inject

internal class DevSuite @Inject constructor(
    private val repository: PreferenceRepository
) {

    suspend fun signInWithDebugUser(activity: FragmentActivity) {
        repository.saveAccountId("firezone").collect()
        repository.saveToken("SFMyNTY.g2gDaAN3CGlkZW50aXR5bQAAACQwNjQ4YzY2OS1lZjYwLTQxMWEtODAyZC01ZjA1ZWU3MTkxNDl3Bmlnbm9yZW4GALovNRmKAWIAACow.8Yl33v6UeiJhsbDSTA2Z_NTvzoNfYUir4TVxUj0s3q8").collect()

        val intent = Intent(activity, MainActivity::class.java)
        activity.startActivity(intent)
        activity.finish()
    }
}
