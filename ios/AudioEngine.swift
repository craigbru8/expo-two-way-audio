import AVFoundation
import Foundation

class AudioEngine {
    private var avAudioEngine = AVAudioEngine()
    private var speechPlayer = AVAudioPlayerNode()
    private var engineConfigChangeObserver: Any?
    private var sessionInterruptionObserver: Any?
    private var mediaServicesResetObserver: Any?
    private var routeChangeObserver: Any?
    
    public private(set) var inputFormat: AVAudioFormat
    public private(set) var outputFormat: AVAudioFormat
    public private(set) var isRecording = false
    
    public var onMicDataCallback: ((Data) -> Void)?
    public var onInputVolumeCallback: ((Float) -> Void)?
    public var onOutputVolumeCallback: ((Float) -> Void)?
    public var onAudioInterruptionCallback: ((String) -> Void)?
    public var onRawAudioLevelCallback: ((Float) -> Void)?
    public var onErrorCallback: ((String, String) -> Void)?
    public var onAudioRouteChangeCallback: ((String) -> Void)?
    
    private var inputLevelTimer: Timer?
    private var outputLevelTimer: Timer?
    
    private var inputBuffer = [Float](repeating: 0, count: 2048)
    private var outputBuffer = [Float](repeating: 0, count: 2048)
    private var inputBufferIndex = 0
    private var outputBufferIndex = 0
    
    private var hasFirstInputBeenDiscarded = false
    private var discardRecording = false
    private var discardFirstInputMillis = 2000
    
    private var isTornDown = false
    
    enum AudioEngineError: Error {
        case audioFormatError
    }
    
    init() throws {
        avAudioEngine.attach(speechPlayer)
        
        guard let inputFmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let outputFmt = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else {
            throw AudioEngineError.audioFormatError
        }
        inputFormat = inputFmt
        outputFormat = outputFmt
        print("AudioEngine initialized with dual sample rates:")
        print("  Input format: \(String(describing: inputFormat))")
        print("  Output format: \(String(describing: outputFormat))")
        
        engineConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avAudioEngine,
            queue: .main) { [weak self] _ in
                self?.checkEngineIsRunning()
            }
        sessionInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main) { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main) { [weak self] _ in
                self?.handleMediaServicesWereReset()
            }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        
        self.setupAudioSession()
        self.setup()
        self.start()
    }
    
    deinit {
        removeObservers()
    }
    
    private func removeObservers() {
        if let observer = engineConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigChangeObserver = nil
        }
        if let observer = sessionInterruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            sessionInterruptionObserver = nil
        }
        if let observer = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(observer)
            mediaServicesResetObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }
    
    private func emitError(code: String, message: String) {
        onErrorCallback?(code, message)
    }
    
    private func handleRouteChange(_ notification: Notification) {
        guard !isTornDown else { return }
        
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        let reasonStr: String
        switch reason {
        case .newDeviceAvailable: reasonStr = "newDeviceAvailable"
        case .oldDeviceUnavailable: reasonStr = "oldDeviceUnavailable"
        case .categoryChange: reasonStr = "categoryChange"
        case .override: reasonStr = "override"
        case .wakeFromSleep: reasonStr = "wakeFromSleep"
        case .noSuitableRouteForCategory: reasonStr = "noSuitableRouteForCategory"
        case .routeConfigurationChange: reasonStr = "routeConfigurationChange"
        @unknown default:
            reasonStr = "other(\(reasonValue))"
        }
        onAudioRouteChangeCallback?(reasonStr)
        checkEngineIsRunning()
    }
    
    func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .defaultToSpeaker, 
                .allowBluetooth, 
                .allowBluetoothA2DP
            ])
        } catch {
            print("Could not set the audio category: \(error.localizedDescription)")
            emitError(code: "AUDIO_SESSION", message: "setCategory: \(error.localizedDescription)")
        }
        
        do {
            try session.setPreferredSampleRate(max(inputFormat.sampleRate, outputFormat.sampleRate))
        } catch {
            print("Could not set the preferred sample rate: \(error.localizedDescription)")
            emitError(code: "AUDIO_SESSION", message: "setPreferredSampleRate: \(error.localizedDescription)")
        }
        
        do {
            try session.setPreferredIOBufferDuration(0.032)
        } catch {
            print("Could not set the preferred IO buffer duration: \(error.localizedDescription)")
            emitError(code: "AUDIO_SESSION", message: "setPreferredIOBufferDuration: \(error.localizedDescription)")
        }
        
        do {
            try session.setActive(true)
        } catch {
            print("Could not set the audio session as active")
            emitError(code: "AUDIO_SESSION", message: "setActive(true) failed")
        }
    }
    
    func setup() {
        let input = avAudioEngine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            print("Could not enable voice processing \(error)")
            emitError(code: "VOICE_PROCESSING", message: error.localizedDescription)
            return
        }
        
        avAudioEngine.inputNode.isVoiceProcessingInputMuted = !isRecording
        
        let output = avAudioEngine.outputNode
        let mainMixer = avAudioEngine.mainMixerNode
        
        avAudioEngine.connect(speechPlayer, to: mainMixer, format: outputFormat)
        avAudioEngine.connect(mainMixer, to: output, format: nil)
        
        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, when in
            if self?.isRecording == true && self?.discardRecording == false {
                self?.processMicrophoneBuffer(buffer)
                self?.updateInputVolume()
            }
        }
        
        mainMixer.installTap(onBus: 0, bufferSize: 768, format: outputFormat) { [weak self] buffer, when in
            self?.processOutputBuffer(buffer)
            self?.updateOutputVolume()
        }
        
        avAudioEngine.prepare()
    }
    
    func processMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else {
            print("Error: Could not access channel data")
            emitError(code: "MIC_PIPELINE", message: "Could not access microphone channel data")
            return
        }
        
        let frameCount = Int(buffer.frameLength)
        var int16Samples = [Int16](repeating: 0, count: frameCount)
        
        var rawLevel: Float = 0.0
        for i in 0..<frameCount {
            let floatSample = max(-1.0, min(1.0, channelData[i]))
            int16Samples[i] = Int16(floatSample * Float(Int16.max))
            
            inputBuffer[inputBufferIndex] = floatSample
            inputBufferIndex = (inputBufferIndex + 1) % inputBuffer.count
            
            rawLevel += abs(floatSample)
        }
        
        onRawAudioLevelCallback?(rawLevel / Float(frameCount))
        
        let data = Data(bytes: int16Samples, count: frameCount * MemoryLayout<Int16>.size)
        
        onMicDataCallback?(data)
    }
    
    func processOutputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else {
            print("Error: Could not access channel data")
            emitError(code: "OUTPUT_PIPELINE", message: "Could not access output channel data")
            return
        }
        
        let frameCount = Int(buffer.frameLength)
        
        for i in 0..<frameCount {
            let floatSample = max(-1.0, min(1.0, channelData[i]))
            outputBuffer[outputBufferIndex] = floatSample
            outputBufferIndex = (outputBufferIndex + 1) % outputBuffer.count
        }
    }
    
    func start() {
        guard !isTornDown else { return }
        do {
            try avAudioEngine.start()
        } catch {
            print("Could not start audio engine: \(error)")
            emitError(code: "ENGINE_START", message: error.localizedDescription)
        }
    }
    
    func playPCMData(_ pcmData: Data) {
        guard !isTornDown else { return }
        
        if !hasFirstInputBeenDiscarded {
            self.hasFirstInputBeenDiscarded = true
            self.discardRecording = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(discardFirstInputMillis)) {
                self.discardRecording = false
            }
        }
        
        guard let buffer = createBuffer(from: pcmData) else {
            print("Failed to create audio buffer")
            emitError(code: "PLAYBACK", message: "Failed to create audio buffer")
            return
        }
        speechPlayer.scheduleBuffer(buffer)
        
        if !speechPlayer.isPlaying {
            speechPlayer.play()
        }
    }

    
    private func createBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count) / 2
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        data.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
            if let sourcePtr = rawBufferPointer.baseAddress?.assumingMemoryBound(to: Int16.self),
               let destPtr = buffer.floatChannelData?[0] {
                for i in 0..<Int(frameCount) {
                    destPtr[i] = Float(sourcePtr[i]) / Float(Int16.max)
                }
            }
        }
        
        return buffer
    }
    
    func bypassVoiceProcessing(_ bypass: Bool) {
        let input = avAudioEngine.inputNode
        input.isVoiceProcessingBypassed = bypass
    }
    
    func toggleRecording(_ val: Bool) -> Bool {
        guard !isTornDown else { return false }
        isRecording = val
        if !isRecording {
            avAudioEngine.inputNode.isVoiceProcessingInputMuted = true
            inputBuffer = [Float](repeating: 0, count: 2048)
            updateInputVolume()
        } else {
            avAudioEngine.inputNode.isVoiceProcessingInputMuted = false
        }
        print("Recording \(isRecording ? "started" : "stopped")")
        
        return isRecording
    }
    
    func stopRecordingAndPlayer(){
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Could not set the audio session to inactive: \(error)")
        }
        toggleRecording(false)
        speechPlayer.stop()
        updateOutputVolume()
    }
    
    // MARK: - Background Audio Approach
    // This implementation follows the recommended approach for conversational AI:
    // 1. No background audio capability - conversations pause when app backgrounds
    // 2. Graceful interruption handling - clear audio state and notify user
    // 3. Manual resume only - users must explicitly restart conversations
    // 4. Better UX - matches user expectations for voice conversations
    
    func resumeRecordingAndPlayer(){
        guard !isTornDown else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Could not set the audio session to active: \(error)")
        }
        self.checkEngineIsRunning()
        isRecording = toggleRecording(true)
        speechPlayer.play()
    }
    
    func tearDown() {
        isTornDown = true
        removeObservers()

        let wasRecording = isRecording
        if wasRecording {
            isRecording = false
            avAudioEngine.inputNode.isVoiceProcessingInputMuted = true
        }
        speechPlayer.stop()
        avAudioEngine.stop()

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Could not deactivate audio session during teardown: \(error)")
        }
    }
    
    var isPlaying: Bool {
        return speechPlayer.isPlaying
    }
    
    func clearAudioQueue() {
        speechPlayer.stop()
        outputBuffer = [Float](repeating: 0, count: outputBuffer.count)
        updateOutputVolume()
        print("Audio queue cleared")
    }
    
    private func checkEngineIsRunning() {
        guard !isTornDown else { return }
        if !avAudioEngine.isRunning {
            start()
        }
    }
    
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard !isTornDown else { return }
        
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("Audio session interrupted - gracefully pausing conversation")
            pauseConversation()
            onAudioInterruptionCallback?("began")
        case .ended:
            print("Audio session interruption ended - showing re-engagement notification")
            scheduleReEngagementNotification()
            onAudioInterruptionCallback?("ended")
        @unknown default:
            print("Unknown audio interruption type: \(type)")
            onAudioInterruptionCallback?("unknown")
        }
    }
    
    private func pauseConversation() {
        print("Pausing conversation due to interruption")
        self.stopRecordingAndPlayer()
        clearAudioQueue()
    }
    
    private func scheduleReEngagementNotification() {
        print("Conversation paused - user should be notified to re-engage")
    }
    
    private func handleMediaServicesWereReset() {
        guard !isTornDown else { return }
        self.avAudioEngine.stop()
        self.setup()
        self.start()
    }
    
    private func updateInputVolume() {
        let volume = calculateRMSLevel(from: inputBuffer)
        onInputVolumeCallback?(volume)
    }
    
    private func updateOutputVolume() {
        let volume = calculateRMSLevel(from: outputBuffer)
        onOutputVolumeCallback?(volume)
    }
    
    private func calculateRMSLevel(from buffer: [Float]) -> Float {
        let epsilon: Float = 1e-5
        let rmsValue = sqrt(buffer.reduce(0) { $0 + $1 * $1 } / Float(buffer.count))
        
        let dbValue = 20 * log10(max(rmsValue, epsilon))
        
        let minDb: Float = -80.0
        let normalizedValue = max(0.0, min(1.0, (dbValue - minDb) / abs(minDb)))
        
        let expFactor: Float = 2.0
        let adjustedValue = pow(normalizedValue, expFactor)
        
        return adjustedValue
    }
}
