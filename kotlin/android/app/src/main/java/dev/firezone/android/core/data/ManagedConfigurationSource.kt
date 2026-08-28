// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core.data

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.RestrictionsManager
import android.os.Bundle
import androidx.core.content.ContextCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import dev.firezone.android.core.data.model.ManagedConfiguration
import dev.firezone.android.core.di.ApplicationScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

internal data class ManagedConfigurationUpdate(
    val revision: Long,
    val configuration: ManagedConfiguration,
)

@Singleton
internal class ManagedConfigurationSource
    @Inject
    constructor(
        @ApplicationContext private val context: Context,
        private val restrictionsManager: RestrictionsManager,
        private val repository: Repository,
        @ApplicationScope private val applicationScope: CoroutineScope,
    ) {
        private val refreshMutex = Mutex()
        private val _configuration = MutableStateFlow<ManagedConfiguration?>(null)
        val configuration = _configuration.asStateFlow()
        private val _updates = MutableStateFlow<ManagedConfigurationUpdate?>(null)
        val updates = _updates.asStateFlow()

        private var started = false
        private var revision = 0L

        private val restrictionsReceiver =
            object : BroadcastReceiver() {
                override fun onReceive(
                    context: Context,
                    intent: Intent,
                ) {
                    val pendingResult = goAsync()
                    applicationScope.launch {
                        try {
                            refresh()
                        } finally {
                            pendingResult.finish()
                        }
                    }
                }
            }

        @Synchronized
        fun start() {
            if (started) {
                return
            }
            started = true

            ContextCompat.registerReceiver(
                context,
                restrictionsReceiver,
                IntentFilter(Intent.ACTION_APPLICATION_RESTRICTIONS_CHANGED),
                ContextCompat.RECEIVER_EXPORTED,
            )
            applicationScope.launch { refresh() }
        }

        suspend fun refresh(): ManagedConfiguration = refreshUpdate().configuration

        internal suspend fun refreshUpdate(): ManagedConfigurationUpdate =
            refreshMutex.withLock {
                applyRestrictionsLocked(restrictionsManager.applicationRestrictions)
            }

        internal suspend fun refresh(readRestrictions: suspend () -> Bundle): ManagedConfiguration =
            refreshMutex.withLock {
                applyRestrictionsLocked(readRestrictions()).configuration
            }

        internal suspend fun applyRestrictions(bundle: Bundle): ManagedConfiguration =
            refreshMutex.withLock {
                applyRestrictionsLocked(bundle).configuration
            }

        private suspend fun applyRestrictionsLocked(bundle: Bundle): ManagedConfigurationUpdate {
            repository.saveManagedConfiguration(bundle).first()

            val configuration = ManagedConfiguration.from(bundle)
            val update = ManagedConfigurationUpdate(++revision, configuration)
            _configuration.value = configuration
            _updates.value = update
            return update
        }
    }
