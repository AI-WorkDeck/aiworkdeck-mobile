# iOS camera startup and rotation regression

User reports: dev-board #1361 (layout after landscape → portrait, later clarified as affecting multiple pages) and #1362 (project → top-right camera → no preview until Audio → Photo). Release target: 1.6.1.

## Findings and changes

- `CameraService.start()` declines startup while audio is busy, but `HomeView` did not observe busy completion in its camera task identity. A hosted real `HomeView`, actual AAC draft recovery and suspended save callback reproduced the missed retry. Observing `isBusy` now retries on completion. The regression uses a Debug-only camera start callback, so it verifies scheduling rather than hardware frames.
- The conditional landscape/portrait containers replaced the attached `CameraPreview.PreviewView` on every rotation. A hosted view resized through four transitions failed all four identity assertions. `CaptureLayout` now repositions the same header, preview and controls. The preview identity and portrait bounds assertions pass; an XCUITest verifies actual device rotation both on the home capture page and the project full-screen capture page.
- Large iPhones also switch project navigation between compact and split columns. On iPhone 17 Pro Max, the project title disappeared and the first row moved up 52 points after returning to portrait. Explicit title mode alone still lost the 60-point search drawer; the correction fixes the sidebar to an inline title with an always-visible search drawer. This keeps the navigation hierarchy and selection intact.
- Separate tests of initial preview attachment, full-screen presentation and reopening passed without changing `CameraService`. The hypothesized synchronous visibility notification failure was not reproduced and was not patched.
- A first UI assertion immediately after rotation failed; waiting for the system orientation/layout to settle passed on unchanged production code. This transient test failure is not evidence of a persistent layout defect.

## Verification

Xcode 27.1; dedicated iPhone 17 Pro Max / iOS 26.5 simulator; synthetic workspace and audio only.

- Four focused hosted-view tests and the capture rotation UI test pass.
- Contract generation consistency, palette check, TypeScript typecheck and 169 TypeScript tests pass.
- iOS: 134 unit tests, one expected skip for the absent Java loopback fixture, zero failures. WorkspaceFlowTests: 10/10 pass, including both first-backup decisions and repeated capture rotation. RecordingFlowTests: 3/3 pass, including background return, playback and process-termination recovery.
- The first combined run failed three workspace UI cases because the preceding deliberate recording crash retained an invalid draft. A screenshot/accessibility hierarchy confirmed the resulting Recording status alert blocked controls and the backup sheet. Moving only that synthetic draft out of this task's dedicated simulator made all three pass; product alert behavior was not changed. Run crash-recovery UI tests separately from navigation tests, or isolate their simulator data.
- On the baseline, a separate iPhone 17 Pro / iOS 26.5 cross-page test passed project list, files, Settings and Library rotations. Large-screen split navigation hides the compact bottom bar in landscape; the new cross-page test checks its restoration after portrait and keeps primary content checks in both orientations.
- Final iPhone 17 Pro Max cross-page regression passes after the title/search fix: project list, project files, Settings, Library and return through nested full-screen captures. Portrait geometry is restored; before/after screenshots were inspected. Evidence: `/tmp/awd-1361/crossscreen-always-search.xcresult` (1/1), `/tmp/awd-1361/crossscreen-fixed-attachments/`. The failing pre-fix result is `/tmp/awd-1361/crossscreen-installed.xcresult`.
- PR simulator CI passed the full unit suite, password-login UI tests and landscape keyboard layout check. A second agent reviewed the production diff without finding a blocker; small-window scrolling was reviewed but not separately exercised on a smaller device.

Local evidence: `/tmp/awd-1361/isolated-regression.xcresult` (134 unit tests + 10 workspace tests pass; initial cross-page selector failed separately), `/tmp/awd-1361/full-regression.xcresult` (three recording flows pass), `/tmp/awd-1361/rotation-diag-attachments/` (blocking alert), `/tmp/awd-crossscreen-26-pro.xcresult` (baseline cross-page); `/tmp/awd-1361/preview-rotation-red2.xcresult`, `/tmp/awd-camera-busy-1362-red.log`, `/tmp/awd-1361/camera-layout-green.xcresult`; screenshots exported to `/tmp/awd-1361/fixed-shots/`.

## Limits and device retest

The simulator has no physical camera. The known scheduling and preview replacement defects are verified; these tests do not establish that every reported physical-device layout issue has the same cause. The paired physical iPhone was unavailable for testing. Verify the distributed build on iPhone: open a project, tap the top-right camera without switching modes, rotate both ways and back, then visit project files, Settings and Library. Confirm a live preview and that controls remain correctly placed and usable. Camera authorization and actual photo/video output still require that device retest.
