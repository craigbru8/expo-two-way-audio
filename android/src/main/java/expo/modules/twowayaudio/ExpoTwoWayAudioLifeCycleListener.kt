package expo.modules.twowayaudio

import android.app.Activity
import expo.modules.core.interfaces.ReactActivityLifecycleListener

class ExpoTwoWayAudioLifeCycleListener : ReactActivityLifecycleListener {
    override fun onPause(activity: Activity?) {
        super.onPause(activity)
        // Pause recording when app goes to background - user must manually restart
        ExpoTwoWayAudioModule.audioEngine?.pauseRecordingAndPlayer()
    }

    override fun onResume(activity: Activity?) {
        super.onResume(activity)
        // Do NOT auto-resume recording - user must manually restart via app UI
        // This ensures microphone only starts through explicit user action
    }
}
