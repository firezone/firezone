// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.content.Context
import android.net.Uri
import android.webkit.URLUtil
import androidx.core.content.FileProvider
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.Log
import dev.firezone.android.core.data.ManagedConfigurationSource
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import dev.firezone.android.core.data.model.ManagedConfiguration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.net.URISyntaxException
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import javax.inject.Inject

@HiltViewModel
internal class SettingsViewModel
    @Inject
    constructor(
        private val repo: Repository,
        private val managedConfigurationSource: ManagedConfigurationSource,
        private val savedStateHandle: SavedStateHandle,
    ) : ViewModel() {
        private var userConfig: Config = savedStateHandle[DRAFT_USER_CONFIG_KEY] ?: repo.getUserConfigSync()
        private var managedConfiguration: ManagedConfiguration? = managedConfigurationSource.configuration.value
        private var shouldResetFavoritesOnSave: Boolean =
            savedStateHandle[RESET_FAVORITES_ON_SAVE_KEY] ?: false

        private val initialConfig = getEffectiveConfig()
        private val _uiState =
            MutableStateFlow(
                UiState(
                    config = initialConfig,
                    managedStatus = getManagedStatus(),
                    isSaveButtonEnabled = areFieldsValid(initialConfig),
                ),
            )
        val uiState: StateFlow<UiState> = _uiState

        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        init {
            viewModelScope.launch {
                managedConfigurationSource.configuration.filterNotNull().collect { configuration ->
                    managedConfiguration = configuration
                    publishEffectiveConfig()
                }
            }
        }

        fun populateFieldsFromConfig() {
            viewModelScope.launch { managedConfigurationSource.refresh() }
        }

        fun onViewResume(context: Context) {
            val directory = File(context.cacheDir.absolutePath + "/logs")
            viewModelScope.launch(Dispatchers.IO) {
                val totalSize =
                    directory
                        .walkTopDown()
                        .filter { it.isFile }
                        .map { it.length() }
                        .sum()

                _uiState.update { it.copy(logSizeBytes = totalSize) }
            }
        }

        fun onSaveSettingsCompleted() {
            val configToSave = userConfig
            viewModelScope.launch {
                repo.saveUserConfig(configToSave)
                if (shouldResetFavoritesOnSave) {
                    repo.resetFavorites()
                    shouldResetFavoritesOnSave = false
                }
                savedStateHandle.remove<Config>(DRAFT_USER_CONFIG_KEY)
                savedStateHandle.remove<Boolean>(RESET_FAVORITES_ON_SAVE_KEY)
                actionMutableStateFlow.value = ViewAction.NavigateBack
            }
        }

        fun onCancel() {
            shouldResetFavoritesOnSave = false
            savedStateHandle.remove<Config>(DRAFT_USER_CONFIG_KEY)
            savedStateHandle.remove<Boolean>(RESET_FAVORITES_ON_SAVE_KEY)
            actionMutableStateFlow.value = ViewAction.NavigateBack
        }

        fun onAuthUrlChanged(authUrl: String) {
            updateUserConfig(
                isManaged = { it.isAuthUrlManaged },
                update = { copy(authUrl = authUrl) },
            )
        }

        fun onApiUrlChanged(apiUrl: String) {
            updateUserConfig(
                isManaged = { it.isApiUrlManaged },
                update = { copy(apiUrl = apiUrl) },
            )
        }

        fun onLogFilterChanged(logFilter: String) {
            updateUserConfig(
                isManaged = { it.isLogFilterManaged },
                update = { copy(logFilter = logFilter) },
            )
        }

        fun onAccountSlugChanged(accountSlug: String) {
            updateUserConfig(
                isManaged = { it.isAccountSlugManaged },
                update = { copy(accountSlug = accountSlug) },
            )
        }

        fun onStartOnLoginChanged(isChecked: Boolean) {
            updateUserConfig(
                isManaged = { it.isStartOnLoginManaged },
                update = { copy(startOnLogin = isChecked) },
            )
        }

        fun onConnectOnStartChanged(isChecked: Boolean) {
            updateUserConfig(
                isManaged = { it.isConnectOnStartManaged },
                update = { copy(connectOnStart = isChecked) },
            )
        }

        fun deleteLogDirectory(context: Context) {
            viewModelScope.launch(Dispatchers.IO) {
                val logDir = context.cacheDir.absolutePath + "/logs"
                val directory = File(logDir)
                directory.walkTopDown().forEach { file ->
                    file.delete()
                }
                _uiState.update { it.copy(logSizeBytes = 0) }
            }
        }

        fun createLogZip(context: Context) {
            viewModelScope.launch(Dispatchers.IO) {
                val logDir = context.cacheDir.absolutePath + "/logs"
                val sourceFolder = File(logDir)
                val zipFile = File(getLogZipPath(context))

                runCatching { zipFolder(sourceFolder, zipFile) }
                    .onSuccess {
                        val fileUri =
                            FileProvider.getUriForFile(
                                context,
                                "${context.applicationContext.packageName}.provider",
                                zipFile,
                            )
                        actionMutableStateFlow.value = ViewAction.ShareLogs(fileUri)
                    }.onFailure { Log.e(TAG, "Failed to create diagnostic log archive", it) }
            }
        }

        fun resetSettingsToDefaults() {
            userConfig = repo.getDefaultUserConfigSync()
            shouldResetFavoritesOnSave = true
            savedStateHandle[DRAFT_USER_CONFIG_KEY] = userConfig
            savedStateHandle[RESET_FAVORITES_ON_SAVE_KEY] = true
            publishEffectiveConfig()
        }

        fun clearAction() {
            actionMutableStateFlow.value = null
        }

        fun deleteLogZip(context: Context) {
            val zipFile = File(getLogZipPath(context))
            if (zipFile.exists()) {
                zipFile.delete()
            }
        }

        private fun getLogZipPath(context: Context): String = "${context.cacheDir.absolutePath}/logs.zip"

        private fun zipFolder(
            sourceFolder: File,
            zipFile: File,
        ) {
            ZipOutputStream(FileOutputStream(zipFile)).use { zipStream ->
                sourceFolder.walkTopDown().filter { it != sourceFolder }.forEach { file ->
                    val entryName = sourceFolder.toPath().relativize(file.toPath()).toString()
                    if (file.isDirectory) {
                        zipStream.putNextEntry(ZipEntry("$entryName/"))
                        zipStream.closeEntry()
                    } else {
                        zipStream.putNextEntry(ZipEntry(entryName))
                        file.inputStream().use { input ->
                            input.copyTo(zipStream)
                        }
                        zipStream.closeEntry()
                    }
                }
            }
        }

        private fun publishEffectiveConfig() {
            val config = getEffectiveConfig()
            _uiState.update {
                it.copy(
                    config = config,
                    managedStatus = getManagedStatus(),
                    isSaveButtonEnabled = areFieldsValid(config),
                )
            }
        }

        private fun updateUserConfig(
            isManaged: (ManagedConfigStatus) -> Boolean,
            update: Config.() -> Config,
        ) {
            if (!isManaged(getManagedStatus())) {
                userConfig = userConfig.update()
                savedStateHandle[DRAFT_USER_CONFIG_KEY] = userConfig
            }
            publishEffectiveConfig()
        }

        private fun getEffectiveConfig(): Config =
            managedConfiguration?.let { repo.getEffectiveConfig(userConfig, it) }
                ?: repo.getEffectiveConfigFromPersistedManaged(userConfig)

        private fun getManagedStatus(): ManagedConfigStatus = managedConfiguration?.managedStatus() ?: repo.getManagedStatus()

        private fun areFieldsValid(config: Config): Boolean =
            URLUtil.isValidUrl(config.authUrl) &&
                isUriValid(config.apiUrl) &&
                config.logFilter.isNotBlank()

        private fun isUriValid(uri: String): Boolean =
            try {
                URI(uri)
                true
            } catch (e: URISyntaxException) {
                false
            }

        internal data class UiState(
            val config: Config,
            val managedStatus: ManagedConfigStatus,
            val isSaveButtonEnabled: Boolean = false,
            val logSizeBytes: Long = 0,
        )

        internal sealed class ViewAction {
            data object NavigateBack : ViewAction()

            data class ShareLogs(
                val uri: Uri,
            ) : ViewAction()
        }

        companion object {
            private const val DRAFT_USER_CONFIG_KEY = "settingsUserDraftConfig"
            private const val RESET_FAVORITES_ON_SAVE_KEY = "resetFavoritesOnSave"
            private const val TAG = "SettingsViewModel"
        }
    }
