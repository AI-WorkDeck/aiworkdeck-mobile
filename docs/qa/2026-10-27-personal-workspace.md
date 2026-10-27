<!-- SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Personal workspace verification — 2026-10-27

All network data used in tests is synthetic. No real account, backend deployment, Apple profile or client release was changed.

| Check | Observed result |
| --- | --- |
| `npm run typecheck` | Passed |
| `npm test` | 249 tests passed (includes mini persisted pending/history recovery and APNs 20-language resources) |
| `node contract/tools/check.mjs` | Passed, 20-language source/generation and APNs resources |
| Android `:app:assembleCnDebug :app:compileIntlDebugKotlin :app:testCnDebugUnitTest` | Final recovery build passed; 124 unit tests passed, including 6 personal-workspace tests |
| Harmony `assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon` | Final recovery build passed, unsigned HAP; 6 recovery behavior tests passed with platform/render stubs |
| iOS full `WorkdeckTests` | 165 executed, 2 existing environment-dependent skips, 0 failures; includes 6 personal-workspace cases |
| iOS `WorkdeckUITests/PersonalWorkspaceFlowTests` | Passed on dedicated iPhone 17 Pro / iOS 26.5 simulator (28.2s in final navigation suite) |
| iOS real-root navigation regression | 13 passed, 0 failed, 0 skipped in 372.4s on the same dedicated simulator |

The iOS flow starts on Personal assistant, sends a synthetic question without a selected project, verifies its answer/source, switches to Calendar, opens the event and associated file names, visits Projects, reaches Capture, returns to Projects, and verifies Calendar and Personal assistant remain reachable after the capture view hides its tab bar. The first run exposed keyboard occlusion of the tab bar; sending now dismisses the keyboard. A crowded toolbar was replaced by compact actions, and the path was rerun successfully.

Artifacts are retained under `artifacts/personal-1539/`: personal assistant, calendar, event detail and project-list screenshots. Source timestamps use the same localized date-format style as existing queue and file viewers. The simulator and all fixtures contain synthetic data only.

Not yet verified: physical-device lock-screen delivery / battery optimizations, real APNs registration and server delivery, WeChat subscription messages (no approved template), and Android/Harmony visual/device walkthroughs. Local reminders use the last fetched snapshot and are not equivalent to live remote push. No signing changes or release/deployment were performed.

Full iOS unit command (dedicated synthetic simulator; private derived data):

```sh
cd ios
xcodebuild test -scheme Workdeck -only-testing:WorkdeckTests \
  -destination 'platform=iOS Simulator,id=1E31D308-B2E2-4EC8-A00F-D7FFF0F01785' \
  -derivedDataPath /tmp/awd-personal-ios-build \
  -resultBundlePath /tmp/awd-personal-full-unit-final.xcresult
```

The final run executed 165 tests in 17.7 seconds with no failures. The two pre-existing skips are AudioRecorderIntegrationTests (simulator microphone permission is not granted) and ProjectFilesLoopbackTests (requires the separate isolated Java loopback fixture); both are recorded in the result bundle. The UI result bundle is `/tmp/awd-personal-complete.xcresult`; it has one passing end-to-end route test and retained screenshots. The final iOS/mini API copy is clean-pinned to server commit `0e296133905966a07b9495a15e5aa2fb13cd70ff`.


The final navigation regression uses the real `PersonalWorkspaceView` for workspace and recording fixtures; the previous recording-only root route is removed. Existing capture position, touchability, recording continuity and reader-state assertions are retained. This exposed two layout regressions: the Capture tab moved the shutter upward by 49 points compared with project capture, and the project toolbar overlapped the global tabs. Capture now uses its existing full-screen layout and returns through its existing close action; project quick capture and Library reserve list space above the tabs. Both project actions are now checked after every rotation. The final suite passed all 13 cases without skips: CaptureContinuity (1), CrossScreenRotation (4), DuoWorkspaceContinuity (1), PersonalWorkspaceFlow (1), paused audio/video and silence reminder (3), and the three CI-selected WorkspaceFlow cases.

Final navigation command:

```sh
cd ios
xcodebuild test -scheme Workdeck -parallel-testing-enabled NO \
  -only-testing:WorkdeckUITests/CaptureContinuityTests \
  -only-testing:WorkdeckUITests/CrossScreenRotationTests \
  -only-testing:WorkdeckUITests/DuoWorkspaceContinuityTests \
  -only-testing:WorkdeckUITests/PersonalWorkspaceFlowTests \
  -only-testing:WorkdeckUITests/RecordingFlowTests/testPausedAudioIsObviousAndCanResumeAndPauseAgain \
  -only-testing:WorkdeckUITests/RecordingFlowTests/testPausedVideoIsObviousAndCanResumeAndPauseAgain \
  -only-testing:WorkdeckUITests/RecordingFlowTests/testSilenceReminderOffersSaveAndContinuesWithoutStopping \
  -only-testing:WorkdeckUITests/WorkspaceFlowTests/testCaptureLayoutSurvivesRepeatedRotationAndProjectEntry \
  -only-testing:WorkdeckUITests/WorkspaceFlowTests/testLandscapeLoginControlsRemainReachableAfterShowingKeyboard \
  -only-testing:WorkdeckUITests/WorkspaceFlowTests/testProjectFilesQuotePreviewAndRotationContinuity \
  -destination 'platform=iOS Simulator,id=1E31D308-B2E2-4EC8-A00F-D7FFF0F01785' \
  -derivedDataPath /tmp/awd-personal-ios-build \
  -resultBundlePath /tmp/awd-personal-navigation-final.xcresult
```

Observed output: `Executed 13 tests, with 0 failures` and `TEST SUCCEEDED`. The result summary independently reports 13 passed / 0 failed / 0 skipped. Console log: `/tmp/awd-personal-navigation-final.log`. Contract validation and `git diff --check` also passed after the final source changes. These are iPhone simulator results; they do not establish Duo posture support or physical-device delivery.
