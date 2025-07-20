package uz.shs.better_player_plus


import androidx.media3.exoplayer.DefaultLoadControl


internal class CustomDefaultLoadControl {
    /**
     * The default minimum duration of media that the player will attempt to ensure is buffered
     * at all times, in milliseconds.
     */

    val minBufferMs: Int

    /**
     * The default maximum duration of media that the player will attempt to buffer, in milliseconds.
     */

    val maxBufferMs: Int

    /**
     * The default duration of media that must be buffered for playback to start or resume following
     * a user action such as a seek, in milliseconds.
     */

    val bufferForPlaybackMs: Int

    /**
     * he default duration of media that must be buffered for playback to resume after a rebuffer,
     * in milliseconds. A rebuffer is defined to be caused by buffer depletion rather than a user
     * action.
     */
 
    val bufferForPlaybackAfterRebufferMs: Int

    constructor() {
     minBufferMs = 5000         // Lowered for faster startup
    maxBufferMs = 50000        // 50 seconds is reasonable
    bufferForPlaybackMs = 2500   // A bit higher to be safer
    bufferForPlaybackAfterRebufferMs = 5000 // A bit higher to be safer
    }

    constructor(
        minBufferMs: Int?,
        maxBufferMs: Int?,
        bufferForPlaybackMs: Int?,
        bufferForPlaybackAfterRebufferMs: Int?
    ) {
        this.minBufferMs = minBufferMs ?: DefaultLoadControl.DEFAULT_MIN_BUFFER_MS
        this.maxBufferMs = maxBufferMs ?: DefaultLoadControl.DEFAULT_MAX_BUFFER_MS
        this.bufferForPlaybackMs =
            bufferForPlaybackMs ?: DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS
        this.bufferForPlaybackAfterRebufferMs = bufferForPlaybackAfterRebufferMs
            ?: DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS
    }
}