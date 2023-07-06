package dev.firezone.android.core

import android.content.SharedPreferences
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.Response

private const val PORTAL_URL_KEY = "portalUrl"

internal class BaseUrlInterceptor(
    private val sharedPreferences: SharedPreferences
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()
        val baseUrl = sharedPreferences.getString(PORTAL_URL_KEY, "").orEmpty().toHttpUrl()
        val newUrl = originalRequest.url.newBuilder()
            .scheme(baseUrl.scheme)
            .host(baseUrl.host)
            .port(baseUrl.port)
            .build()
        val newRequest = originalRequest.newBuilder()
            .url(newUrl)
            .build()
        return chain.proceed(newRequest)
    }
}
