/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
package dev.firezone.android.core.presentation

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R

@AndroidEntryPoint
internal class MainActivity : AppCompatActivity(R.layout.activity_main) {
    // fail fast if the native library is not loaded
    companion object {
        init {
            System.loadLibrary("connlib")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {}
}
