/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core

import android.content.SharedPreferences
import dev.firezone.android.BuildConfig
import okhttp3.Interceptor
import okhttp3.Response
import okhttp3.HttpUrl

private const val ACCOUNT_ID_KEY = "accountId"

internal class BaseUrlInterceptor(
    private val sharedPreferences: SharedPreferences,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()
        val accountId = sharedPreferences.getString(ACCOUNT_ID_KEY, "") ?: ""
        val newUrl = HttpUrl.parse("${BuildConfig.AUTH_URL}/$accountId") ?: ""
        val newRequest =
            originalRequest.newBuilder()
                .url(newUrl)
                .build()
        return chain.proceed(newRequest)
    }
}
