# Speechmatics Two Way Audio

Expo module for capturing and playing pcm audio data in react-native apps (iOS and Android).

The aim of the module is to facilitate creating real-time conversational apps. The following features are provided:

- Request audio recording permissions
- Get clean (applying Acoustic Echo Cancelling) microphone samples in PCM format (1 channel 16 bit at 16kHz)
- Play audio samples in PCM format (1 channel 16 bit at 24kHz). Playback happens through main speaker unless external audio sources are connected.
- Provide volume level both for the input and output samples. Float between 0 and 1.
- [iOS only] Get microphone mode and prompt user to select a microphone mode.

Check out our [examples/](./examples) to see the module in action.

## Installation

```
npm i @speechmatics/expo-two-way-audio
```

## Usage

Please check out our [examples/](./examples) to get full sample code.

1. Request permissions for recording audio

   ```JSX
   import {useMicrophonePermissions} from "@speechmatics/expo-two-way-audio";

   const [micPermission, requestMicPermission] = useMicrophonePermissions();
   console.log(micPermission);
   ```

1. Initialize the module before calling any audio functionality.

   ```JSX
   useEffect(() => {
       const initializeAudio = async () => {
           await initialize();
       };
       initializeAudio();
   }, []);

   ```

1. Play audio

   > [!NOTE]
   > The sample below uses the `buffer` module:
   > `npm install buffer`

   ```JSX
    import { Buffer } from "buffer";

    // As an example, let's play pcm data hardcoded in a variable.
    // The examples/basic-usage does this. Check it out for real base64 data.
    const audioChunk = "SOME PCM DATA BASE64 ENCODED HERE"
    const buffer = Buffer.from(audioChunk, "base64");
    const pcmData = new Uint8Array(buffer);
    playPCMData(pcmData);
   ```

1. Get microphone samples

   ```JSX
   // Set up a function to deal with microphone sample events.
   // In this case just print the data in the console.
   useExpoTwoWayAudioEventListener(
       "onMicrophoneData",
       useCallback<MicrophoneDataCallback>((event) => {
           console.log(`MIC DATA: ${event.data}`);
       }, []),
   );

   // Unmute the microphone to get microphone data events
   toggleRecording(true);
   ```

## Background Audio Handling

This module is designed for **conversational AI applications** and follows best practices for background audio:

### Why No Background Audio Capability?

Unlike music or podcast apps, conversational AI requires:
- **Bidirectional real-time processing** - Both recording and playback simultaneously
- **Voice processing features** - Acoustic Echo Cancellation (AEC) and noise suppression
- **Active user engagement** - Voice conversations naturally pause when users switch apps

**Background audio doesn't work reliably for these use cases** because:
- Voice processing (AEC/noise cancellation) gets disabled in background
- Real-time audio processing becomes unreliable
- Input taps may stop working
- It doesn't fit Apple's intended background audio model

### Recommended Approach ✅

The module automatically handles interruptions gracefully:

```jsx
// Listen for audio interruptions
useExpoTwoWayAudioEventListener(
  "onAudioInterruption",
  useCallback((event) => {
    switch (event.data) {
      case "began":
        // Conversation paused - show user feedback
        showNotification("🎙️ Conversation paused");
        break;
      case "ended":
        // Show re-engagement prompt
        showNotification("🔔 Tap to continue your conversation");
        break;
    }
  }, []),
);
```

**What happens when app goes to background:**
1. Audio session interruption is detected
2. Recording and playback are gracefully stopped
3. Audio queue is cleared to prevent confusion
4. User must manually restart the conversation

This provides a **better user experience** than pretending background audio works when it doesn't.

## Notes

Some audio features of expo-two-way-audio like Acoustic Echo Cancelling, noise reduction or microphone modes (iOS) don't work on simulator. Run the example on a real device to test these features.

### Dual Sample Rate Configuration

This module uses different sample rates for input and output to optimize for both AEC performance and audio quality:
- **Input (Microphone)**: 16kHz - Optimized for voice processing and AEC
- **Output (Speaker)**: 24kHz - Higher quality playback (expects 24kHz input audio)

The different sample rates help maintain low latency while providing better acoustic echo cancellation performance.

```bash
# iOS
npx expo run:ios --device --configuration Release

# Android
npx expo run:android --device --variant release
```

For Android, the following permissions are needed: `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`. In Expo apps they can bee added in your `app.json` file:

```javascript
expo.android.permissions: ["RECORD_AUDIO", "MODIFY_AUDIO_SETTINGS"]
```
