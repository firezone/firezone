package dev.firezone.android.core.presentation

import android.net.Uri
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.navigation.fragment.NavHostFragment
import dev.firezone.android.R
import dagger.hilt.android.AndroidEntryPoint

private const val DEEP_LINK_KEY = "deepLink"

@AndroidEntryPoint
internal class MainActivity : AppCompatActivity(R.layout.activity_main) {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val navHostFragment =
            supportFragmentManager.findFragmentById(R.id.fragmentContainer) as NavHostFragment
        val navController = navHostFragment.navController

        val deepLink = intent.extras?.getString(DEEP_LINK_KEY).orEmpty()
        if (deepLink.isNotEmpty()) navController.navigate(Uri.parse(deepLink))
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {}
}
