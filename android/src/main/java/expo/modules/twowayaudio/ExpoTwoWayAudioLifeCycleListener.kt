package expo.modules.twowayaudio

import android.app.Activity
import expo.modules.core.interfaces.ReactActivityLifecycleListener

class ExpoTwoWayAudioLifeCycleListener : ReactActivityLifecycleListener {
    override fun onPause(activity: Activity?) {
        super.onPause(activity)
        // Gracefully pause conversation when app goes to background
        // Voice conversations naturally pause when users switch apps
        ExpoTwoWayAudioModule.audioEngine?.let { engine ->
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                engine.pauseRecordingAndPlayer()
                engine.clearAudioQueue()
            }
        }
    }

    override fun onResume(activity: Activity?) {
        super.onResume(activity)
        // Do NOT auto-resume recording - user must manually restart via app UI
        // This follows Apple's guidelines and provides better user experience:
        // - Voice conversations require active user engagement
        // - Users should explicitly choose to continue conversations
        // - Prevents unexpected microphone activation
    }
}
