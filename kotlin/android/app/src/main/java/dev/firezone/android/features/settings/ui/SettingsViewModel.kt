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
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
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
        private val savedStateHandle: SavedStateHandle,
    ) : ViewModel() {
        private val initialConfig = savedStateHandle[DRAFT_CONFIG_KEY] ?: repo.getConfigSync()
        private val _uiState =
            MutableStateFlow(
                UiState(
                    config = initialConfig,
                    managedStatus = repo.getManagedStatus(),
                    isSaveButtonEnabled = areFieldsValid(initialConfig),
                ),
            )
        val uiState: StateFlow<UiState> = _uiState

        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        private val config: Config get() = _uiState.value.config

        private var shouldResetFavoritesOnSave = false

        fun onViewResume(context: Context) {
            val directory = File(context.cacheDir.absolutePath + "/logs")
            viewModelScope.launch(Dispatchers.IO) {
                val totalSize =
                    directory
                        .walkTopDown()
                        .filter { it.isFile }
                        .map { it.length() }
                        .sum()

                _uiState.update {
                    it.copy(
                        logSizeBytes = totalSize,
                    )
                }
            }
        }

        fun onSaveSettingsCompleted() {
            viewModelScope.launch {
                repo.saveSettings(config).collect {
                    if (shouldResetFavoritesOnSave) {
                        repo.resetFavorites()
                        shouldResetFavoritesOnSave = false
                    }
                    savedStateHandle.remove<Config>(DRAFT_CONFIG_KEY)
                    actionMutableStateFlow.value = ViewAction.NavigateBack
                }
            }
        }

        fun onCancel() {
            savedStateHandle.remove<Config>(DRAFT_CONFIG_KEY)
            actionMutableStateFlow.value = ViewAction.NavigateBack
        }

        fun onConfigChanged(config: Config) {
            savedStateHandle[DRAFT_CONFIG_KEY] = config
            _uiState.update {
                it.copy(
                    config = config,
                    isSaveButtonEnabled = areFieldsValid(config),
                )
            }
        }

        fun deleteLogDirectory(context: Context) {
            viewModelScope.launch(Dispatchers.IO) {
                val logDir = context.cacheDir.absolutePath + "/logs"
                val directory = File(logDir)
                directory.walkTopDown().forEach { file ->
                    file.delete()
                }
                _uiState.update {
                    it.copy(
                        logSizeBytes = 0,
                    )
                }
            }
        }

        fun createLogZip(context: Context) {
            viewModelScope.launch(Dispatchers.IO) {
                val logDir = context.cacheDir.absolutePath + "/logs"
                val sourceFolder = File(logDir)
                val zipFile = File(getLogZipPath(context))

                runCatching { zipFolder(sourceFolder, zipFile) }
                    .onSuccess {
                        val fileURI =
                            FileProvider.getUriForFile(
                                context,
                                "${context.applicationContext.packageName}.provider",
                                zipFile,
                            )
                        actionMutableStateFlow.value = ViewAction.ShareLogs(fileURI)
                    }.onFailure { Log.e(TAG, "Failed to create diagnostic log archive", it) }
            }
        }

        fun resetSettingsToDefaults() {
            val config = repo.getDefaultConfigSync()
            savedStateHandle[DRAFT_CONFIG_KEY] = config
            shouldResetFavoritesOnSave = true
            _uiState.update {
                it.copy(
                    config = config,
                    managedStatus = repo.getManagedStatus(),
                    isSaveButtonEnabled = areFieldsValid(config),
                )
            }
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

        private fun getLogZipPath(context: Context) = "${context.cacheDir.absolutePath}/logs.zip"

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
            private const val DRAFT_CONFIG_KEY = "settingsDraftConfig"
            private const val TAG = "SettingsViewModel"
        }
    }
