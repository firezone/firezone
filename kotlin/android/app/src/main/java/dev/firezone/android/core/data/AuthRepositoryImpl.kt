package dev.firezone.android.core.data

import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.util.Base64
import javax.inject.Inject
import kotlin.random.Random

internal class AuthRepositoryImpl @Inject constructor(
    private val coroutineDispatcher: CoroutineDispatcher,
    private val sharedPreferences: SharedPreferences
) : AuthRepository {

    override fun generateCsrfToken(): Flow<String> = flow {
        val str = (1..CSRF_LENGTH)
            .map { Random.nextInt(0, chars.size).let { chars[it] } }
            .joinToString("")

        val encodedStr: String = Base64.getEncoder().encodeToString(str.toByteArray())

        sharedPreferences
            .edit()
            .putString(CSRF_KEY, encodedStr)
            .apply()

        emit(encodedStr)
    }.flowOn(coroutineDispatcher)

    companion object {
        private const val CSRF_KEY = "csrf"
        private const val CSRF_LENGTH = 24
        private val chars : List<Char> = ('a'..'z') + ('A'..'Z') + ('0'..'9')
    }
}
