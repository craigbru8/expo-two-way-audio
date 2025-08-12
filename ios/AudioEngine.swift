import AVFoundation
import Foundation

class AudioEngine {
    private var avAudioEngine = AVAudioEngine()
    private var speechPlayer = AVAudioPlayerNode()
    private var engineConfigChangeObserver: Any?
    private var sessionInterruptionObserver: Any?
    private var mediaServicesResetObserver: Any?
    
    public private(set) var inputFormat: AVAudioFormat
    public private(set) var outputFormat: AVAudioFormat
    public private(set) var isRecording = false
    
    public var onMicDataCallback: ((Data) -> Void)?
    public var onInputVolumeCallback: ((Float) -> Void)?
    public var onOutputVolumeCallback: ((Float) -> Void)?
    public var onAudioInterruptionCallback: ((String) -> Void)?
    public var onRawAudioLevelCallback: ((Float) -> Void)?
    
    private var inputLevelTimer: Timer?
    private var outputLevelTimer: Timer?
    
    private var inputBuffer = [Float](repeating: 0, count: 2048)
    private var outputBuffer = [Float](repeating: 0, count: 2048)
    private var inputBufferIndex = 0
    private var outputBufferIndex = 0
    
    private var hasFirstInputBeenDiscarded = false
    private var discardRecording = false
    private var discardFirstInputMillis = 2000
    
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
        
        self.setupAudioSession()
        self.setup()
        self.start()
    }
    
    deinit {
        if let observer = engineConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = sessionInterruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        
        do {
            // Optimized for real-time AI conversation
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .defaultToSpeaker, 
                .allowBluetooth, 
                .allowBluetoothA2DP
                // Removed .mixWithOthers to prevent other apps from interfering
            ])
        } catch {
            print("Could not set the audio category: \(error.localizedDescription)")
        }
        
        do {
            // Set preferred sample rate to the higher of the two formats for better quality
            try session.setPreferredSampleRate(max(inputFormat.sampleRate, outputFormat.sampleRate))
        } catch {
            print("Could not set the preferred sample rate: \(error.localizedDescription)")
        }
        
        do {
            // Set preferred buffer duration for low latency (32ms)
            try session.setPreferredIOBufferDuration(0.032)
        } catch {
            print("Could not set the preferred IO buffer duration: \(error.localizedDescription)")
        }
        
        do {
            try session.setActive(true)
        } catch {
            print("Could not set the audio session as active")
        }
    }
    
    func setup() {
        let input = avAudioEngine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            print("Could not enable voice processing \(error)")
            return
        }
        
        avAudioEngine.inputNode.isVoiceProcessingInputMuted = !isRecording
        
        let output = avAudioEngine.outputNode
        let mainMixer = avAudioEngine.mainMixerNode
        
        // Connect speech player to mixer with output format (24kHz)
        avAudioEngine.connect(speechPlayer, to: mainMixer, format: outputFormat)
        // Connect mixer to output with output format (24kHz)
        avAudioEngine.connect(mainMixer, to: output, format: outputFormat)
        
        // Install tap on input with input format (16kHz)
        // Buffer size 512 samples = ~32ms at 16kHz (optimized for real-time AI)
        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, when in
            // We don't do any input processing (no volume calculation or passing mic data to the callback) if discardRecording == true
            // See comment in the playPCMData function
            if self?.isRecording == true && self?.discardRecording == false {
                self?.processMicrophoneBuffer(buffer)
                self?.updateInputVolume()
            }
        }
        
        // Install tap on mixer with output format (24kHz)
        // Buffer size 768 samples = ~32ms at 24kHz (maintains same latency as input)
        mainMixer.installTap(onBus: 0, bufferSize: 768, format: outputFormat) { [weak self] buffer, when in
            self?.processOutputBuffer(buffer)
            self?.updateOutputVolume()
        }
        
        avAudioEngine.prepare()
    }
    
    func processMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else {
            print("Error: Could not access channel data")
            return
        }
        
        let frameCount = Int(buffer.frameLength)
        var int16Samples = [Int16](repeating: 0, count: frameCount)
        
        // Convert float samples to Int16 and update input buffer for volume calculation
        var rawLevel: Float = 0.0
        for i in 0..<frameCount {
            let floatSample = max(-1.0, min(1.0, channelData[i]))
            int16Samples[i] = Int16(floatSample * Float(Int16.max))
            
            inputBuffer[inputBufferIndex] = floatSample
            inputBufferIndex = (inputBufferIndex + 1) % inputBuffer.count
            
            // Calculate raw audio level for VAD
            rawLevel += abs(floatSample)
        }
        
        // Send raw audio level for potential VAD implementation
        onRawAudioLevelCallback?(rawLevel / Float(frameCount))
        
        // Create Data object from Int16 samples
        let data = Data(bytes: int16Samples, count: frameCount * MemoryLayout<Int16>.size)
        
        // Send the data to the callback
        onMicDataCallback?(data)
    }
    
    func processOutputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else {
            print("Error: Could not access channel data")
            return
        }
        
        let frameCount = Int(buffer.frameLength)
        
        // Update output buffer for volume calculation
        for i in 0..<frameCount {
            let floatSample = max(-1.0, min(1.0, channelData[i]))
            outputBuffer[outputBufferIndex] = floatSample
            outputBufferIndex = (outputBufferIndex + 1) % outputBuffer.count
        }
    }
    
    func start() {
        do {
            try avAudioEngine.start()
        } catch {
            print("Could not start audio engine: \(error)")
        }
    }
    
    func playPCMData(_ pcmData: Data) {
        // Looks like we don't get a proper AEC for the very first chunks of audio that we play.
        // To work around this, we will discard microphone input for the first few milliseconds.
        // This will give the AEC time to adapt to the playback audio.
        // We achieve this by setting discardRecording to true for a short time (this doesn't actually mute the input). It's just not processed in the tap.
        // Audio that is not processed by the input tap is not sent to the callback and therefore not sent to the server.
        if !hasFirstInputBeenDiscarded {
            self.hasFirstInputBeenDiscarded = true
            self.discardRecording = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(discardFirstInputMillis)) {
                self.discardRecording = false
            }
        }
        
        guard let buffer = createBuffer(from: pcmData) else {
            print("Failed to create audio buffer")
            return
        }
        speechPlayer.scheduleBuffer(buffer)
        
        if !speechPlayer.isPlaying {
            speechPlayer.play()
        }
    }

    
    private func createBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count) / 2 // 16-bit input = 2 bytes per frame
        
        // Create buffer with output format (24kHz) - assume input data is also 24kHz
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
        isRecording = val
        if !isRecording {
            avAudioEngine.inputNode.isVoiceProcessingInputMuted = true
            // Reset input buffer, so that volume levels report 0
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
        stopRecordingAndPlayer()
        avAudioEngine.stop()
    }
    
    var isPlaying: Bool {
        return speechPlayer.isPlaying
    }
    
    func clearAudioQueue() {
        speechPlayer.stop()
        // Reset output buffer for clean volume reporting
        outputBuffer = [Float](repeating: 0, count: outputBuffer.count)
        updateOutputVolume()
        print("Audio queue cleared")
    }
    
    private func checkEngineIsRunning() {
        if !avAudioEngine.isRunning {
            start()
        }
    }
    
    private func handleAudioSessionInterruption(_ notification: Notification) {
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
        // Gracefully pause the conversation
        print("Pausing conversation due to interruption")
        self.stopRecordingAndPlayer()
        // Clear any pending audio to avoid confusion when resuming
        clearAudioQueue()
    }
    
    private func scheduleReEngagementNotification() {
        // This would typically trigger a local notification or UI update
        // The actual notification scheduling should be handled by the React Native layer
        print("Conversation paused - user should be notified to re-engage")
        // The onAudioInterruptionCallback will inform the JS layer to handle UI updates
    }
    
    private func handleMediaServicesWereReset() {
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
        let epsilon: Float = 1e-5 // To avoid log(0)
        let rmsValue = sqrt(buffer.reduce(0) { $0 + $1 * $1 } / Float(buffer.count))
        
        // Convert to decibels
        let dbValue = 20 * log10(max(rmsValue, epsilon))
        
        // Normalize decibel value to 0-1 range
        // Assuming minimum audible is -60dB and maximum is 0dB
        let minDb: Float = -80.0
        let normalizedValue = max(0.0, min(1.0, (dbValue - minDb) / abs(minDb)))
        
        // Optional: Apply exponential factor to push smaller values down
        let expFactor: Float = 2.0 // Adjust this value to change the curve
        let adjustedValue = pow(normalizedValue, expFactor)
        
        return adjustedValue
    }
}
