package dev.firezone.android.features.webview.ui

import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Bundle
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import dev.firezone.android.R
import dev.firezone.android.databinding.ActivityWebViewBinding
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
internal class WebViewActivity : AppCompatActivity(R.layout.activity_web_view) {

    private lateinit var binding: ActivityWebViewBinding
    private val viewModel: WebViewViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityWebViewBinding.inflate(layoutInflater)

        setupActionObservers()
    }

    private fun setupActionObservers() {
        viewModel.actionLiveData.observe(this) { action ->
            when (action) {
                is WebViewViewModel.ViewAction.ShowError -> showError()
            }
        }
    }

    private fun setupWebView(url: String) {
        binding.webview.apply {
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                setSupportMultipleWindows(true)
                allowFileAccess = true
                allowContentAccess = true
                javaScriptCanOpenWindowsAutomatically = true
                cacheMode = WebSettings.LOAD_NO_CACHE
                useWideViewPort = true
            }
            loadUrl(url)
            webViewClient = WebViewBrowser()
        }
    }

    private inner class WebViewBrowser : WebViewClient() {

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            super.onPageStarted(view, url, favicon)
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            super.onPageFinished(view, url)
        }

        override fun onPageCommitVisible(view: WebView?, url: String?) {
            super.onPageCommitVisible(view, url)
        }

        override fun onReceivedSslError(
            view: WebView?,
            handler: SslErrorHandler?,
            error: SslError?
        ) {
            super.onReceivedSslError(view, handler, error)
        }

        override fun onReceivedError(
            view: WebView?,
            request: WebResourceRequest?,
            error: WebResourceError?
        ) {
            showError()
            super.onReceivedError(view, request, error)
        }

        override fun shouldOverrideUrlLoading(
            view: WebView?, request: WebResourceRequest?
        ): Boolean {
            return super.shouldOverrideUrlLoading(view, request)
        }
    }

    private fun showError() {
        AlertDialog.Builder(this)
            .setTitle(R.string.error_dialog_title)
            .setMessage(R.string.error_dialog_message)
            .setPositiveButton(
                R.string.error_dialog_button_text
            ) { _, _ ->
                this@WebViewActivity.finish()
            }
            .setIcon(R.drawable.ic_firezone_logo)
            .show()
    }
}
