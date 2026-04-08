package expo.modules.twowayaudio

import android.app.Activity
import android.util.Log
import expo.modules.core.interfaces.ReactActivityLifecycleListener

class ExpoTwoWayAudioLifeCycleListener : ReactActivityLifecycleListener {
    override fun onPause(activity: Activity?) {
        super.onPause(activity)
        ExpoTwoWayAudioModule.audioEngine?.let { engine ->
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                try {
                    engine.pauseRecordingAndPlayer()
                    engine.clearAudioQueue()
                } catch (e: Exception) {
                    Log.w("ExpoTwoWayAudio", "onPause audio cleanup failed safely", e)
                }
            }
        }
    }

    override fun onResume(activity: Activity?) {
        super.onResume(activity)
    }
}
