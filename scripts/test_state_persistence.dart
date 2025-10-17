// ignore_for_file: avoid_print

import 'package:jell_mpv_dart/src/state.dart';

void main() async {
  print('Testing state persistence...');
  print('State directory: ${AppState.getStateDirectory().path}');
  print('State file: ${AppState.getStateFile().path}');

  // Load current state
  final state = await AppState.load();
  print('Current state: volume=${state.volume}, muted=${state.muted}');

  // Save a test state
  final testState = state.copyWith(volume: 75, muted: false);
  await testState.save();
  print('Saved test state: volume=75, muted=false');

  // Load again to verify
  final loadedState = await AppState.load();
  print(
    'Loaded state: volume=${loadedState.volume}, '
    'muted=${loadedState.muted}',
  );

  if (loadedState.volume == 75 && !loadedState.muted) {
    print('✅ Test PASSED! State persistence working correctly.');
  } else {
    print('❌ Test FAILED! State not persisted correctly.');
  }
}
