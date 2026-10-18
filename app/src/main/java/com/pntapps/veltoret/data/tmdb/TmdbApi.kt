package com.pntapps.veltoret.data.tmdb

import kotlinx.serialization.json.JsonObject
import okhttp3.Interceptor
import okhttp3.Response
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query
import java.io.IOException

class TmdbKeyMissingException : IOException("Add your TMDB API key in Settings to fetch posters and details")

interface TmdbApi {
    @GET("search/movie")
    suspend fun searchMovie(
        @Query("query") query: String,
        @Query("year") year: Int? = null,
        @Query("include_adult") includeAdult: Boolean = false,
    ): TmdbPage<TmdbMovieSummary>

    @GET("search/tv")
    suspend fun searchTv(
        @Query("query") query: String,
        @Query("first_air_date_year") year: Int? = null,
        @Query("include_adult") includeAdult: Boolean = false,
    ): TmdbPage<TmdbTvSummary>

    @GET("movie/{id}")
    suspend fun movie(
        @Path("id") id: Int,
        @Query("append_to_response") append: String = "credits,release_dates",
    ): TmdbMovieDetail

    @GET("tv/{id}")
    suspend fun tv(
        @Path("id") id: Int,
        @Query("append_to_response") append: String = "credits,content_ratings",
    ): TmdbTvDetail

    @GET("movie/{id}/recommendations")
    suspend fun movieRecommendations(@Path("id") id: Int, @Query("page") page: Int = 1): TmdbPage<TmdbMovieSummary>

    @GET("tv/{id}/recommendations")
    suspend fun tvRecommendations(@Path("id") id: Int, @Query("page") page: Int = 1): TmdbPage<TmdbTvSummary>

    @GET("tv/{id}/season/{season}")
    suspend fun season(@Path("id") id: Int, @Path("season") season: Int): TmdbSeasonDetail

    @GET("configuration")
    suspend fun configuration(): JsonObject
}

/**
 * Accepts either a v3 API key or a v4 "API Read Access Token" (a JWT, sent as a bearer token).
 * Every request is pinned to English (US).
 */
class TmdbAuthInterceptor(private val keyProvider: () -> String) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val key = keyProvider().trim()
        if (key.isEmpty()) throw TmdbKeyMissingException()
        val original = chain.request()
        val url = original.url.newBuilder().apply {
            if (original.url.queryParameter("language") == null) addQueryParameter("language", "en-US")
            if (!key.isBearerToken()) addQueryParameter("api_key", key)
        }.build()
        val request = original.newBuilder().url(url).apply {
            if (key.isBearerToken()) header("Authorization", "Bearer $key")
        }.build()
        return chain.proceed(request)
    }

    private fun String.isBearerToken() = startsWith("eyJ")
}

object TmdbImages {
    private const val BASE = "https://image.tmdb.org/t/p/"
    fun poster(path: String?, size: String = "w342") = path?.let { BASE + size + it }
    fun backdrop(path: String?, size: String = "w1280") = path?.let { BASE + size + it }
    fun still(path: String?, size: String = "w300") = path?.let { BASE + size + it }
    fun profile(path: String?, size: String = "w185") = path?.let { BASE + size + it }
}
