import ExpoModulesCore

let ON_MIC_DATA_EVENT_NAME = "onMicrophoneData"
let ON_INPUT_VOLUME_LEVEL_EVENT_NAME = "onInputVolumeLevelData"
let ON_OUTPUT_VOLUME_LEVEL_EVENT_NAME = "onOutputVolumeLevelData"
let ON_RECORDING_CHANGE_EVENT_NAME = "onRecordingChange"
let ON_AUDIO_INTERRUPTION_EVENT_NAME = "onAudioInterruption"
let ON_RAW_AUDIO_LEVEL_EVENT_NAME = "onRawAudioLevel"
let ON_ERROR_EVENT_NAME = "onError"
let ON_AUDIO_ROUTE_CHANGE_EVENT_NAME = "onAudioRouteChange"

public class ExpoTwoWayAudioModule: Module {
    private var audioEngine: AudioEngine?
    public func definition() -> ModuleDefinition {
        Name("ExpoTwoWayAudio")

        OnCreate {
            let permissionsManager = self.appContext?.permissions
            EXPermissionsMethodsDelegate.register(
                [
                    MicrophonePermissionRequester()
                ],
                withPermissionsManager: permissionsManager
            )

        }

        Function("isInitialized") { () -> Bool in
            return self.audioEngine != nil
        }

        AsyncFunction("initialize") { (promise: Promise) in
            do {
                if self.audioEngine != nil {
                    promise.resolve(nil)
                    return
                }
                self.audioEngine = try AudioEngine()
                self.setupMicrophoneCallback()
                self.setupInputAudioLevelCallback()
                self.setupOutputAudioLevelCallback()
                self.setupAudioInterruptionCallback()
                self.setupRawAudioLevelCallback()
                self.setupErrorAndRouteCallbacks()
                promise.resolve(nil)
            } catch {
                print("Failed to initialize AudioEngine: \(error)")
                self.sendEvent(
                    ON_ERROR_EVENT_NAME,
                    [
                        "code": "INIT_FAILED",
                        "message": "Failed to initialize AudioEngine: \(error.localizedDescription)"
                    ])
                promise.reject(
                    "INIT_FAILED",
                    "Failed to initialize AudioEngine: \(error.localizedDescription)"
                )
            }
        }

        Function("isRecording") { () -> Bool in
            guard let audioEngine = self.audioEngine else {
                print("AudioEngine not initialized")
                return false
            }
            return audioEngine.isRecording
        }

        Function("toggleRecording") { (val: Bool) -> Bool in
            guard let audioEngine = self.audioEngine else {
                print("AudioEngine not initialized")
                return false
            }
            let isRecording = audioEngine.toggleRecording(val)
            self.sendEvent(
                ON_RECORDING_CHANGE_EVENT_NAME,
                [
                    "data": isRecording
                ])
            return isRecording
        }

        Function("getMicrophoneModeIOS") { () -> String in
            if #available(iOS 15.0, *) {
                let mode = AVCaptureDevice.preferredMicrophoneMode.rawValue
                var micMode = ""

                switch mode {
                case 1:
                    micMode = MicrophoneMode.wideSpectrum.rawValue
                case 2:
                    micMode = MicrophoneMode.voiceIsolation.rawValue
                default:
                    micMode = MicrophoneMode.standard.rawValue
                }
                return micMode
            }
            print("Please update your ios")

            return ""
        }

        Function("setMicrophoneModeIOS") {
            if #available(iOS 15, *) {
                if AVCaptureDevice.preferredMicrophoneMode != .voiceIsolation {
                    AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                }
            } else {
                print("This code only runs on iOS 14 and lower")
            }
        }

        Function("tearDown") {
            self.audioEngine?.tearDown()
            self.audioEngine = nil
        }

        Function("restart") {
            self.audioEngine?.resumeRecordingAndPlayer()
            self.sendEvent(
                ON_RECORDING_CHANGE_EVENT_NAME,
                [
                    "data": audioEngine?.isRecording
                ])

        }

        Function("playPCMData") { (pcmData: Data) in
            self.audioEngine?.playPCMData(pcmData)
        }

        Function("bypassVoiceProcessing") { (bypass: Bool) in
            self.audioEngine?.bypassVoiceProcessing(bypass)
        }

        Function("isPlaying") { () -> Bool in
            return self.audioEngine?.isPlaying ?? false
        }
        
        Function("clearAudioQueue") {
            self.audioEngine?.clearAudioQueue()
        }

        AsyncFunction("getMicrophonePermissionsAsync") { (promise: Promise) in
            EXPermissionsMethodsDelegate.getPermissionWithPermissionsManager(
                self.appContext?.permissions,
                withRequester: MicrophonePermissionRequester.self,
                resolve: promise.resolver,
                reject: promise.legacyRejecter
            )
        }

        AsyncFunction("requestMicrophonePermissionsAsync") { (promise: Promise) in
            EXPermissionsMethodsDelegate.askForPermission(
                withPermissionsManager: self.appContext?.permissions,
                withRequester: MicrophonePermissionRequester.self,
                resolve: promise.resolver,
                reject: promise.legacyRejecter
            )
        }

        // Define the events that can be emitted
        Events([
            ON_MIC_DATA_EVENT_NAME,
            ON_INPUT_VOLUME_LEVEL_EVENT_NAME,
            ON_OUTPUT_VOLUME_LEVEL_EVENT_NAME,
            ON_RECORDING_CHANGE_EVENT_NAME,
            ON_AUDIO_INTERRUPTION_EVENT_NAME,
            ON_RAW_AUDIO_LEVEL_EVENT_NAME,
            ON_ERROR_EVENT_NAME,
            ON_AUDIO_ROUTE_CHANGE_EVENT_NAME,
        ])
    }

    private func setupMicrophoneCallback() {
        audioEngine?.onMicDataCallback = { [weak self] data in
            self?.sendEvent(
                ON_MIC_DATA_EVENT_NAME,
                [
                    "data": data
                ])
        }
    }

    private func setupInputAudioLevelCallback() {
        audioEngine?.onInputVolumeCallback = { [weak self] level in
            self?.sendEvent(
                ON_INPUT_VOLUME_LEVEL_EVENT_NAME,
                [
                    "data": level
                ])
        }
    }

    private func setupOutputAudioLevelCallback() {
        audioEngine?.onOutputVolumeCallback = { [weak self] level in
            self?.sendEvent(
                ON_OUTPUT_VOLUME_LEVEL_EVENT_NAME,
                [
                    "data": level
                ])
        }
    }

    private func setupAudioInterruptionCallback() {
        audioEngine?.onAudioInterruptionCallback = { [weak self] data in
            self?.sendEvent(
                ON_AUDIO_INTERRUPTION_EVENT_NAME,
                [
                    "data": data
                ])
            self?.sendEvent(
                ON_RECORDING_CHANGE_EVENT_NAME,
                [
                    "data": self?.audioEngine?.isRecording
                ])
        }
    }
    
    private func setupRawAudioLevelCallback() {
        audioEngine?.onRawAudioLevelCallback = { [weak self] level in
            self?.sendEvent(
                ON_RAW_AUDIO_LEVEL_EVENT_NAME,
                [
                    "data": level
                ])
        }
    }

    private func setupErrorAndRouteCallbacks() {
        audioEngine?.onErrorCallback = { [weak self] code, message in
            self?.sendEvent(
                ON_ERROR_EVENT_NAME,
                [
                    "code": code,
                    "message": message
                ])
        }
        audioEngine?.onAudioRouteChangeCallback = { [weak self] reason in
            self?.sendEvent(
                ON_AUDIO_ROUTE_CHANGE_EVENT_NAME,
                [
                    "data": reason
                ])
        }
    }

    enum MicrophoneMode: String, Enumerable {
        case standard
        case voiceIsolation
        case wideSpectrum
    }
}
