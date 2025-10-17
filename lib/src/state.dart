import 'dart:convert';
import 'dart:io';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:path/path.dart' as p;

part 'state.freezed.dart';
part 'state.g.dart';

/// Application state that persists across sessions.
@freezed
class AppState with _$AppState {
  const factory AppState({
    /// The last known volume level (0-100).
    @Default(100) int volume,

    /// Whether the player was muted.
    @Default(false) bool muted,
  }) = _AppState;

  const AppState._();

  factory AppState.fromJson(Map<String, dynamic> json) =>
      _$AppStateFromJson(json);

  /// Get the platform-specific state directory path.
  static Directory getStateDirectory() {
    final String stateDir;

    if (Platform.isWindows) {
      // Windows: %APPDATA%\jell_mpv_dart
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        stateDir = p.join(appData, 'jell_mpv_dart');
      } else {
        // Fallback to user profile
        final userProfile = Platform.environment['USERPROFILE'] ?? '.';
        stateDir = p.join(userProfile, '.jell_mpv_dart');
      }
    } else if (Platform.isMacOS) {
      // macOS: ~/Library/Application Support/jell_mpv_dart
      final home = Platform.environment['HOME'] ?? '.';
      stateDir = p.join(
        home,
        'Library',
        'Application Support',
        'jell_mpv_dart',
      );
    } else {
      // Linux/Unix: ~/.config/jell_mpv_dart
      final xdgConfigHome = Platform.environment['XDG_CONFIG_HOME'];
      final home = Platform.environment['HOME'] ?? '.';
      final configBase = xdgConfigHome ?? p.join(home, '.config');
      stateDir = p.join(configBase, 'jell_mpv_dart');
    }

    final dir = Directory(stateDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Get the state file path.
  static File getStateFile() {
    final dir = getStateDirectory();
    return File(p.join(dir.path, 'state.json'));
  }

  /// Load the state from disk.
  static Future<AppState> load() async {
    try {
      final file = getStateFile();
      if (!file.existsSync()) {
        return const AppState();
      }

      final contents = await file.readAsString();
      final json = jsonDecode(contents) as Map<String, dynamic>;
      return AppState.fromJson(json);
    } catch (error) {
      // Return default state on any error
      return const AppState();
    }
  }

  /// Save the state to disk.
  Future<void> save() async {
    try {
      final file = getStateFile();
      final json = toJson();
      const encoder = JsonEncoder.withIndent('  ');
      final contents = encoder.convert(json);
      await file.writeAsString(contents);
    } catch (error) {
      // Silently fail - state persistence is not critical
    }
  }
}
