/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.data

import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.security.SecureRandom
import javax.inject.Inject

internal class AuthRepositoryImpl
    @Inject
    constructor(
        private val coroutineDispatcher: CoroutineDispatcher,
        private val sharedPreferences: SharedPreferences,
    ) : AuthRepository {
        override fun generateNonce(key: String): Flow<String> =
            flow {
                val random = SecureRandom.getInstanceStrong()
                val bytes = ByteArray(NONCE_LENGTH)
                random.nextBytes(bytes)
                val encodedStr: String = bytes.joinToString("") { "%02x".format(it) }

                sharedPreferences
                    .edit()
                    .putString(key, encodedStr)
                    .apply()

                emit(encodedStr)
            }.flowOn(coroutineDispatcher)

        companion object {
            private const val NONCE_LENGTH = 32
        }
    }
