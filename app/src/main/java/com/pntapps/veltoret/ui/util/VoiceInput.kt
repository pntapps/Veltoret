package com.pntapps.veltoret.ui.util

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext

/**
 * Speech to text through the device's own voice input (Google's on phones, Google TV's on TVs); no
 * microphone permission or speech engine of our own. Returns a function that starts listening, or null
 * when the device has no voice input (then don't show a mic). The manifest's `<queries>` entry lets
 * Android 11+ see the voice input app.
 */
@Composable
fun rememberVoiceInput(prompt: String, onResult: (String) -> Unit): (() -> Unit)? {
    val context = LocalContext.current
    val result by rememberUpdatedState(onResult)
    val intent = remember(prompt) {
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
    }
    val available = remember { intent.resolveActivity(context.packageManager) != null }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult
        r.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.takeIf { it.isNotBlank() }?.let(result)
    }
    if (!available) return null
    return remember { { runCatching { launcher.launch(intent) }; Unit } }
}
