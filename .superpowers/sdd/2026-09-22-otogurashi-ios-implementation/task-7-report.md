# Task 7 report

Status: the Flutter creation loop and native playback/thumbnail contracts are
implemented and locally verified. Swift/AVFoundation compilation and the real
Simulator integration test remain pending GitHub Actions; no device pass is
claimed.

## Flow and dependency contracts

- `AppDependencies.bootstrap` obtains the native managed root, opens the real
  SQLite `ProjectDatabase`, and injects `SqliteProjectRepository`,
  `SqliteAssetRepository` with `NativeAssetInspector`, `PlatformMediaGateway`,
  and `PlatformMediaPresentationGateway`. Production screens do not create fake
  repositories or media completions.
- Onboarding waits for an explicit tap. The bundled path is labeled as a
  synthetic sample and copies the three checked-in MP4s through the normal
  inspected asset import. The personal path opens real camera/Photos capture.
- `CreationController` persists project clip order and recipes, analyzes through
  the native gateway, serializes arrangement mutations, and delegates preview
  publication to the observable and stale-safe `RenderController`.
- Capture/import returns managed staging media to `AssetRepository`; clip cards
  request real native thumbnails. A failed real thumbnail says it cannot be
  displayed, while synthetic sample fallback remains explicitly labeled.
- Three arrangement styles, a second seeded result, original/source comparison,
  three video layouts in the adjustment sheet, drag reorder, and accessible
  reorder menu all generate through the same persisted recipe/render path.
- Completion presents the generated preview and intentionally leaves save/share
  unavailable until Task 9. It does not report a fake export success.

## Native presentation and session ownership

- The existing `dev.otogurashi/media` plugin now provides guarded thumbnail and
  AVPlayer platform-view operations. Play, pause, exact seek, position, duration,
  ended state, replay from zero, and item failures are exposed to Dart.
- Dart polls native AVPlayer state while active, stops when native playback stops
  or reaches the end, ignores responses from replaced platform views, and shows
  playback errors. Both arrangement and completion views expose a visible
  position slider.
- `AudioSessionCoordinator` is the sole category owner. Opening prepared capture
  synchronously pauses app playback, claims `.playAndRecord` before starting the
  capture session, and retains ownership through the capture route. Playback is
  rejected while capture owns the session. Release/interruption stops capture
  before serialized deactivation. AVCapture automatic audio-session
  configuration is disabled; platform playback pauses on interruption and app
  background and never auto-resumes.

## Interaction and visual behavior

- `Pressable` has one VoiceOver tap action, a 44-point minimum target, touch-down
  scale, drag cancellation, and zero-duration Reduce Motion behavior. Working
  calls to action contain decorated content rather than disabled nested buttons.
- The camera keeps video unobstructed between a recessed lid underside at the
  top and highlighted cup rim/body top at the bottom. The recording action uses
  coral with a dark contrast-safe label. Clip collection uses warm paper and a
  metal clipboard clip; playback uses a subdued dark TV surround.
- List-based screens remain reachable at 390x844 and with 1.8x Japanese text.
  Local screenshot rendering loads `C:/Windows/Fonts/NotoSansJP-VF.ttf` only at
  test time; no Windows font or external device frame is committed.

## Verification

- `flutter test`: 66 passed, with the opt-in visual capture test explicitly
  skipped in the ordinary suite.
- `flutter test test/features/creation_flow_test.dart
  --dart-define=TASK7_VISUALS=true`: 3 passed and regenerated five actual Flutter
  widget screenshots at 390x844.
- `flutter analyze --fatal-infos`: no issues.
- Focused coverage includes semantic activation and cancelled presses, full
  synthetic create/style/complete flow, large text and 44-point controls,
  method-channel thumbnail/playback payloads, playback end/replay, stale view
  state, post-dispose safety, observable render state, cancellation on render
  controller disposal, and previous render stale-result/cancel-drain cases.
- Screenshot artifacts are in ignored task scratch:
  `task-7-artifacts/capture.png`, `capture-ready.png`, `clip-list.png`,
  `clip-list-ready.png`, and `completed.png`.

## Pending native evidence

- Windows cannot compile or run the Swift AVPlayer, AVAudioSession,
  AVCaptureSession, and AVAssetImageGenerator additions. GitHub Actions must run
  the unsigned iOS build/native tests and the Simulator synthetic-project
  integration test before these are called native-passing.
- A physical-device camera/Photos/playback, VoiceOver order, background,
  interruption, route-change, and ordinary-speed motion check remains external.
- Task 8 owns full library/settings/editor history. Task 9 owns real export,
  Photos save, share sheet, and remix entry points.
