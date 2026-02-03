// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.content.Context
import android.content.Intent
import android.webkit.URLUtil
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.data.model.Config
import dev.firezone.android.core.data.model.ManagedConfigStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
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
    ) : ViewModel() {
        private val _uiState = MutableStateFlow(UiState())
        val uiState: StateFlow<UiState> = _uiState

        private val actionMutableStateFlow = MutableStateFlow<ViewAction?>(null)
        val actionStateFlow: StateFlow<ViewAction?> = actionMutableStateFlow

        private var config =
            Config(
                authUrl = "",
                apiUrl = "",
                logFilter = "",
                accountSlug = "",
                startOnLogin = false,
                connectOnStart = false,
            )

        fun populateFieldsFromConfig() {
            viewModelScope.launch {
                repo.getConfig().collect {
                    config = it
                    onFieldUpdated()
                    actionMutableStateFlow.value =
                        ViewAction.FillSettings(
                            it,
                            managedStatus = repo.getManagedStatus(),
                        )
                }
            }
        }

        fun onViewResume(context: Context) {
            val directory = File(context.cacheDir.absolutePath + "/logs")
            val totalSize =
                directory
                    .walkTopDown()
                    .filter { it.isFile }
                    .map { it.length() }
                    .sum()

            _uiState.value =
                _uiState.value.copy(
                    logSizeBytes = totalSize,
                )
        }

        fun onSaveSettingsCompleted() {
            viewModelScope.launch {
                repo.saveSettings(config).collect {
                    actionMutableStateFlow.value = ViewAction.NavigateBack
                }
            }
        }

        fun onCancel() {
            actionMutableStateFlow.value = ViewAction.NavigateBack
        }

        fun onValidateAuthUrl(authUrl: String) {
            this.config.authUrl = authUrl
            onFieldUpdated()
        }

        fun onValidateApiUrl(apiUrl: String) {
            this.config.apiUrl = apiUrl
            onFieldUpdated()
        }

        fun onValidateLogFilter(logFilter: String) {
            this.config.logFilter = logFilter
            onFieldUpdated()
        }

        fun onValidateAccountSlug(accountSlug: String) {
            this.config.accountSlug = accountSlug
            onFieldUpdated()
        }

        fun onStartOnLoginChanged(isChecked: Boolean) {
            this.config.startOnLogin = isChecked
            onFieldUpdated()
        }

        fun onConnectOnStartChanged(isChecked: Boolean) {
            this.config.connectOnStart = isChecked
            onFieldUpdated()
        }

        fun deleteLogDirectory(context: Context) {
            viewModelScope.launch {
                val logDir = context.cacheDir.absolutePath + "/logs"
                val directory = File(logDir)
                directory.walkTopDown().forEach { file ->
                    file.delete()
                }
                _uiState.value =
                    _uiState.value.copy(
                        logSizeBytes = 0,
                    )
            }
        }

        fun createLogZip(context: Context) {
            viewModelScope.launch {
                val logDir = context.cacheDir.absolutePath + "/logs"
                val sourceFolder = File(logDir)
                val zipFile = File(getLogZipPath(context))

                zipFolder(sourceFolder, zipFile).collect()

                val sendIntent =
                    Intent(Intent.ACTION_SEND).apply {
                        putExtra(
                            Intent.EXTRA_SUBJECT,
                            "Sharing diagnostic logs",
                        )

                        // Add additional details to the share intent, for ex: email body.
                        // putExtra(
                        //    Intent.EXTRA_TEXT,
                        //    "Sharing diagnostic logs for $input"
                        // )

                        val fileURI =
                            FileProvider.getUriForFile(
                                context,
                                "${context.applicationContext.packageName}.provider",
                                zipFile,
                            )
                        putExtra(Intent.EXTRA_STREAM, fileURI)

                        flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                        data = fileURI
                    }
                val shareIntent = Intent.createChooser(sendIntent, null)
                context.startActivity(shareIntent)
            }
        }

        fun resetSettingsToDefaults() {
            config = repo.getDefaultConfigSync()
            repo.resetFavorites()
            onFieldUpdated()
            actionMutableStateFlow.value =
                ViewAction.FillSettings(
                    config = config,
                    managedStatus = repo.getManagedStatus(),
                )
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

        private suspend fun zipFolder(
            sourceFolder: File,
            zipFile: File,
        ) = flow {
            ZipOutputStream(FileOutputStream(zipFile)).use { zipStream ->
                sourceFolder.walkTopDown().forEach { file ->
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
                    emit(Result.success(zipFile))
                }
            }
        }.catch { e ->
            emit(Result.failure(e))
        }.flowOn(Dispatchers.IO)

        private fun getLogZipPath(context: Context) = "${context.cacheDir.absolutePath}/logs.zip"

        private fun onFieldUpdated() {
            _uiState.value =
                _uiState.value.copy(
                    isSaveButtonEnabled = areFieldsValid(),
                )
        }

        private fun areFieldsValid(): Boolean =
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
            val isSaveButtonEnabled: Boolean = false,
            val logSizeBytes: Long = 0,
        )

        internal sealed class ViewAction {
            data object NavigateBack : ViewAction()

            data class FillSettings(
                val config: Config,
                val managedStatus: ManagedConfigStatus,
            ) : ViewAction()
        }
    }
