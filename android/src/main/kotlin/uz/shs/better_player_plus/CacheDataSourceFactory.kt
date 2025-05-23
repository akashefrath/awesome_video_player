package uz.shs.better_player_plus

import android.annotation.SuppressLint
import android.content.Context
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter

@SuppressLint("UnsafeOptInUsageError")
internal class CacheDataSourceFactory(
    val context: Context,
    private val maxCacheSize: Long,
    private val maxFileSize: Long,
    upstreamDataSource: DataSource.Factory? = null
) : DataSource.Factory {

    private var defaultDatasourceFactory: DefaultDataSource.Factory?=null

    init {
        val bandwidthMeter = DefaultBandwidthMeter.Builder(context).build()
        defaultDatasourceFactory = upstreamDataSource?.let { DefaultDataSource.Factory(context, it) }
        defaultDatasourceFactory?.setTransferListener(bandwidthMeter)
    }

    override fun createDataSource(): CacheDataSource {
        val betterPlayerCache = BetterPlayerCache.createCache(context, maxCacheSize)
            ?: throw IllegalStateException("Cache can't be null.")

        return CacheDataSource(
            betterPlayerCache,
            defaultDatasourceFactory?.createDataSource(),
            FileDataSource(),
            CacheDataSink(betterPlayerCache, maxFileSize),
            CacheDataSource.FLAG_BLOCK_ON_CACHE or CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR,
            null
        )
    }
}
