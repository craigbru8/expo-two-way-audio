import ExpoTwoWayAudioModule from "./ExpoTwoWayAudioModule";

export type MicrophoneDataEvent = {
  data: Uint8Array;
};

export type VolumeLevelEvent = {
  data: number;
};

export type RecordingChangeEvent = {
  data: boolean;
};

export type AudioInterruptionEvent = {
  data: string;
};

/** Emitted when the audio route changes (e.g. headphones); iOS only today. */
export type AudioRouteChangeEvent = {
  data: string;
};

/** Structured operational or recoverable errors from native audio. */
export type AudioErrorEvent = {
  code: string;
  message: string;
};

export interface ExpoTwoWayAudioEventMap {
  onMicrophoneData: MicrophoneDataEvent;
  onInputVolumeLevelData: VolumeLevelEvent;
  onOutputVolumeLevelData: VolumeLevelEvent;
  onRecordingChange: RecordingChangeEvent;
  onAudioInterruption: AudioInterruptionEvent;
  onRawAudioLevel: VolumeLevelEvent;
  onError: AudioErrorEvent;
  onAudioRouteChange: AudioRouteChangeEvent;
}

// These are useful for defining `useCallback` types inline
export type MicrophoneDataCallback = (event: MicrophoneDataEvent) => void;
export type VolumeLevelCallback = (event: VolumeLevelEvent) => void;
export type RecordingChangeCallback = (event: RecordingChangeEvent) => void;
export type AudioInterruptionCallback = (event: AudioInterruptionEvent) => void;
export type RawAudioLevelCallback = (event: VolumeLevelEvent) => void;
export type AudioErrorCallback = (event: AudioErrorEvent) => void;
export type AudioRouteChangeCallback = (event: AudioRouteChangeEvent) => void;

export function addExpoTwoWayAudioEventListener<K extends keyof ExpoTwoWayAudioEventMap>(
  eventName: K,
  handler: (ev: ExpoTwoWayAudioEventMap[K]) => void,
) {
  return ExpoTwoWayAudioModule.addListener(eventName, handler);
}
