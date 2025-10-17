# Jellyfin MPV Shim (Dart)

A Jellyfin playback client written in Dart that relays media playback commands from a Jellyfin server to a local mpv player instance.

## Features

✅ **Connectivity**

- WebSocket connection to Jellyfin server
- Auto-reconnect on connection loss
- Registers as remote playback device

✅ **Playback Control**

- Play/Pause/Stop/Seek
- PlayNext command support
- Real-time playback progress reporting
- Pause and mute state synchronization

✅ **Audio/Video**

- Audio track selection
- Subtitle track selection
- Stream quality configuration

✅ **Volume Control**

- Set volume (0-100)
- Volume up/down
- Mute/unmute/toggle mute

✅ **Authentication**

- Username/password authentication
- API key authentication
- Session token management

✅ **Configuration**

- YAML configuration file
- CLI argument overrides
- Flexible mpv customization

## Quick Start

1. Install dependencies: `dart pub get`
2. Copy `config.example.yaml` to `config.yaml`
3. Fill in your Jellyfin credentials
4. Run: `dart run bin/jell_mpv_dart.dart --config config.yaml`

## Configuration

### Authentication Methods

**Method 1: Username/Password (Recommended)**

```yaml
server: https://jellyfin.example.com
userId: YOUR_USER_ID
username: YOUR_USERNAME
password: YOUR_PASSWORD
```

This method authenticates with Jellyfin on startup and obtains a session token. Best for instances without the API Keys UI.

**Method 2: API Key**

```yaml
server: https://jellyfin.example.com
userId: YOUR_USER_ID
accessToken: YOUR_API_KEY
```

**IMPORTANT**: The API key must be user-specific!

1. **Log in** to Jellyfin as the user who will control playback
2. **UserId**: User Settings → Profile (copy the User ID)
3. **accessToken**: User Settings → API Keys → Create New Key
   - The key will be automatically associated with the logged-in user
   - ⚠️ Do NOT use a system/admin API key - it creates anonymous sessions!

### Getting Your User ID

1. Log in to Jellyfin Web UI
2. Go to User Settings → Profile
3. Copy the User ID (a UUID like `b3849ec8-508a-4de1-b697-70d09360ee24`)

## Remote Control

Once the shim is running, you can control it from:

1. **Jellyfin Web UI**: Click the cast icon → select "My MPV Player"
2. **Jellyfin Mobile Apps**: Use the "Play on" feature
3. **Command Line** (for testing):

```bash
# List active sessions
dart run check_sessions.dart

# Test remote control (requires shim to be running)
dart run test_remote_control.dart pause
dart run test_remote_control.dart unpause
dart run test_remote_control.dart volume 50
dart run test_remote_control.dart seek 120
```

### Supported Commands

| Command                          | Description                           |
| -------------------------------- | ------------------------------------- |
| `Play`                           | Start playback of media               |
| `Pause` / `Unpause`              | Pause/resume playback                 |
| `Stop`                           | Stop playback                         |
| `Seek`                           | Jump to a specific position           |
| `SetVolume`                      | Set volume (0-100)                    |
| `VolumeUp` / `VolumeDown`        | Adjust volume by ±5                   |
| `Mute` / `Unmute` / `ToggleMute` | Control mute state                    |
| `SetAudioStreamIndex`            | Switch audio track                    |
| `SetSubtitleStreamIndex`         | Switch subtitle track                 |
| `PlayNext`                       | Skip to next item (stops if no queue) |

All commands automatically update Jellyfin with the current playback state (position, pause state, mute state).

## Testing

```bash
# Run all tests
dart test

# Test session registration
dart test test/session_registration_test.dart
```

The test verifies:

- Authentication works correctly
- Session registers with Jellyfin
- Session has correct UserId (not anonymous)
- Session supports remote control

## Troubleshooting

### Device Not Appearing in "Play On" Dialog

**Symptom**: Session appears in `/Sessions` but with `SupportsRemoteControl: false`

**Root Cause**: The API key is not user-specific, creating an anonymous session (UserId=`00000000...`)

**Solution**:

1. Log in to Jellyfin **as the user** who will use the shim
2. Go to User Settings → API Keys
3. Create a new API key (it will be automatically user-associated)
4. Use this key in your `config.yaml`

**Verify**: Run `dart test` - it will show if the session has the correct UserId
