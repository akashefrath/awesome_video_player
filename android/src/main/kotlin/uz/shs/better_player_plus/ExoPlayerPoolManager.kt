package uz.shs.better_player_plus


import android.annotation.SuppressLint
import android.content.Context
import androidx.media3.common.PriorityTaskManager
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector

@SuppressLint("UnsafeOptInUsageError")
object ExoPlayerPoolManager {
    private const val POOL_SIZE = 3
    private val pool = ArrayDeque<ExoPlayer>()

    fun getOrCreate(
        context: Context,
        trackSelector: DefaultTrackSelector,
        renderersFactory: DefaultRenderersFactory,
        loadControl: DefaultLoadControl
    ): ExoPlayer {
        return synchronized(pool) {
            if (pool.isNotEmpty()) {
                pool.removeFirst()
            } else {
               // ExoPlayer.Builder(context).build()
        ExoPlayer.Builder(context)
            .setTrackSelector(trackSelector)
            .setRenderersFactory(renderersFactory)
            .setLoadControl(loadControl)
            .setPriorityTaskManager(PriorityTaskManager().apply {
                add(0) // priority for buffering
            })
            .build()
            }
        }
    }

    fun release(exoPlayer: ExoPlayer) {
        synchronized(pool) {
            if (pool.size < POOL_SIZE) {
                exoPlayer.stop()
                exoPlayer.clearMediaItems()
                exoPlayer.clearVideoSurface() 
                pool.addLast(exoPlayer)
            } else {
                exoPlayer.release()
            }
        }
    }

    fun releaseAll() {
        synchronized(pool) {
            pool.forEach { it.release() }
            pool.clear()
        }
    }
}
