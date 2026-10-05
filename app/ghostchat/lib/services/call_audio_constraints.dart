/// Audio-processing flags in both the flat form used by desktop and the
/// optional-list form parsed by Android's flutter_webrtc implementation.
Map<String, dynamic> callAudioConstraints() => {
  'echoCancellation': true,
  'noiseSuppression': true,
  'autoGainControl': true,
  'highpassFilter': true,
  'optional': const [
    {'googEchoCancellation': 'true'},
    {'echoCancellation': 'true'},
    {'googEchoCancellation2': 'true'},
    {'googDAEchoCancellation': 'true'},
    {'googNoiseSuppression': 'true'},
    {'googAutoGainControl': 'true'},
    {'googHighpassFilter': 'true'},
  ],
};
