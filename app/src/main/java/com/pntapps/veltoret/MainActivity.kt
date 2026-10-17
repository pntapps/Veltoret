package com.pntapps.veltoret

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.data.settings.AppSettings
import com.pntapps.veltoret.ui.AppShell
import com.pntapps.veltoret.ui.onboarding.OnboardingScreen
import com.pntapps.veltoret.ui.onboarding.OnboardingStep
import com.pntapps.veltoret.ui.theme.VeltoretTheme
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.container
import com.pntapps.veltoret.ui.util.widthClassFor

class MainActivity : ComponentActivity() {

    @Volatile
    private var settingsLoaded = false

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        splash.setKeepOnScreenCondition { !settingsLoaded }
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        val settingsFlow = container.settings.settings
        // Debug-only design aid: `adb shell am start -n com.pntapps.veltoret/.MainActivity --es preview_onboarding Scan`
        // opens any onboarding step without resetting the app.
        val previewStep = if (BuildConfig.DEBUG) {
            intent.getStringExtra("preview_onboarding")?.let { name -> OnboardingStep.entries.firstOrNull { it.name == name } }
        } else null
        setContent {
            val settings: AppSettings? by settingsFlow.collectAsStateWithLifecycle(initialValue = null)
            SideEffect { if (settings != null) settingsLoaded = true }
            VeltoretTheme(oledBlack = settings?.oledBlack == true) {
                BoxWithConstraints(
                    Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.background)
                ) {
                    CompositionLocalProvider(LocalWidthClass provides widthClassFor(maxWidth)) {
                        val current = settings
                        when {
                            current == null -> Unit
                            previewStep != null -> OnboardingScreen(startStep = previewStep)
                            !current.onboardingComplete -> OnboardingScreen()
                            else -> AppShell()
                        }
                    }
                }
            }
        }
    }
}
