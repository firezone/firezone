/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.security.SecureRandom
import java.util.Base64
import javax.inject.Inject

internal class AuthRepositoryImpl
    @Inject
    constructor(
        private val coroutineDispatcher: CoroutineDispatcher,
        private val sharedPreferences: SharedPreferences,
    ) : AuthRepository {
        override fun generateCsrfToken(): Flow<String> =
            flow {
                val random = SecureRandom.getInstanceStrong()
                val bytes = ByteArray(CSRF_LENGTH)
                random.nextBytes(bytes)
                val encodedStr: String = Base64.getEncoder().encodeToString(bytes)

                sharedPreferences
                    .edit()
                    .putString(CSRF_KEY, encodedStr)
                    .apply()

                emit(encodedStr)
            }.flowOn(coroutineDispatcher)

        companion object {
            private const val CSRF_KEY = "csrf"
            private const val CSRF_LENGTH = 24
        }
    }
