package com.pntapps.veltoret.data.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.pntapps.veltoret.BuildConfig
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "settings")

data class AppSettings(
    val onboardingComplete: Boolean = false,
    /** Key the user typed in; empty means "use the developer key from local.properties" (debug only). */
    val tmdbKeyOverride: String = "",
    val oledBlack: Boolean = false,
    val autoPlayNext: Boolean = true,
    val skipSeconds: Int = 85,
    val seekSeconds: Int = 10,
    val preferredAudioLanguage: String = "en",
    /** Empty = subtitles off by default. */
    val preferredSubtitleLanguage: String = "",
    val subtitleScale: Float = 1f,
    val subtitleBackground: Boolean = false,
    val lastScanAt: Long = 0,
    /** Notify on the day a show on the Watchlist airs a new episode. */
    val newEpisodeAlerts: Boolean = true,
) {
    val tmdbKey: String get() = tmdbKeyOverride.ifBlank { BuildConfig.BUNDLED_TMDB_KEY }
}

class SettingsRepository(private val context: Context) {

    private object Keys {
        val onboarding = booleanPreferencesKey("onboarding_complete")
        val tmdbKey = stringPreferencesKey("tmdb_key")
        val oled = booleanPreferencesKey("oled_black")
        val autoPlayNext = booleanPreferencesKey("auto_play_next")
        val skipSeconds = intPreferencesKey("skip_seconds")
        val seekSeconds = intPreferencesKey("seek_seconds")
        val audioLang = stringPreferencesKey("audio_lang")
        val subLang = stringPreferencesKey("sub_lang")
        val subScale = floatPreferencesKey("sub_scale")
        val subBackground = booleanPreferencesKey("sub_background")
        val lastScan = longPreferencesKey("last_scan")
        val newEpisodeAlerts = booleanPreferencesKey("new_episode_alerts")
    }

    val settings: Flow<AppSettings> = context.dataStore.data.map { p ->
        AppSettings(
            onboardingComplete = p[Keys.onboarding] ?: false,
            tmdbKeyOverride = p[Keys.tmdbKey] ?: "",
            oledBlack = p[Keys.oled] ?: false,
            autoPlayNext = p[Keys.autoPlayNext] ?: true,
            skipSeconds = p[Keys.skipSeconds] ?: 85,
            seekSeconds = p[Keys.seekSeconds] ?: 10,
            preferredAudioLanguage = p[Keys.audioLang] ?: "en",
            preferredSubtitleLanguage = p[Keys.subLang] ?: "",
            subtitleScale = p[Keys.subScale] ?: 1f,
            subtitleBackground = p[Keys.subBackground] ?: false,
            lastScanAt = p[Keys.lastScan] ?: 0L,
            newEpisodeAlerts = p[Keys.newEpisodeAlerts] ?: true,
        )
    }

    suspend fun current(): AppSettings = settings.first()

    suspend fun setOnboardingComplete(done: Boolean) = context.dataStore.edit { it[Keys.onboarding] = done }
    suspend fun setTmdbKey(key: String) = context.dataStore.edit { it[Keys.tmdbKey] = key.trim() }
    suspend fun setOledBlack(value: Boolean) = context.dataStore.edit { it[Keys.oled] = value }
    suspend fun setAutoPlayNext(value: Boolean) = context.dataStore.edit { it[Keys.autoPlayNext] = value }
    suspend fun setSkipSeconds(value: Int) = context.dataStore.edit { it[Keys.skipSeconds] = value }
    suspend fun setSeekSeconds(value: Int) = context.dataStore.edit { it[Keys.seekSeconds] = value }
    suspend fun setAudioLanguage(value: String) = context.dataStore.edit { it[Keys.audioLang] = value }
    suspend fun setSubtitleLanguage(value: String) = context.dataStore.edit { it[Keys.subLang] = value }
    suspend fun setSubtitleScale(value: Float) = context.dataStore.edit { it[Keys.subScale] = value }
    suspend fun setSubtitleBackground(value: Boolean) = context.dataStore.edit { it[Keys.subBackground] = value }
    suspend fun setLastScan(time: Long) = context.dataStore.edit { it[Keys.lastScan] = time }
    suspend fun setNewEpisodeAlerts(value: Boolean) = context.dataStore.edit { it[Keys.newEpisodeAlerts] = value }
}
