// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

import android.content.SharedPreferences
import dev.firezone.android.BuildConfig
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

internal class UrlInterceptor(
    private val sharedPreferences: SharedPreferences,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()
        val newUrl = BuildConfig.AUTH_URL.toHttpUrlOrNull()

        val newRequest =
            originalRequest
                .newBuilder()
                .url(newUrl!!)
                .build()
        return chain.proceed(newRequest)
    }
}
