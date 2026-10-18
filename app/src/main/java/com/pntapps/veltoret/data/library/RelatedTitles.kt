package com.pntapps.veltoret.data.library

/** "More like this": TMDB's recommendations for a title, narrowed to the ones in the library. */
object RelatedTitles {
    const val LIMIT = 20

    /** Parses [RecommendationEntity.recommendedIds][com.pntapps.veltoret.data.db.RecommendationEntity]. */
    fun parseIds(csv: String?): List<Int> =
        csv.orEmpty().split(',').mapNotNull { it.trim().toIntOrNull() }

    /** The recommended titles found in [library], in TMDB's order, without [selfId] or repeats. */
    fun <T> inLibrary(recommended: List<Int>, library: Map<Int, T>, selfId: Int, limit: Int = LIMIT): List<T> =
        recommended.asSequence()
            .filter { it != selfId }
            .distinct()
            .mapNotNull { library[it] }
            .take(limit)
            .toList()
}
