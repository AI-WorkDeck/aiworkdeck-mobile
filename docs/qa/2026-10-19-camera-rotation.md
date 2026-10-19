# iOS camera startup and rotation regression

User reports: dev-board #1361 (layout after landscape → portrait, later clarified as affecting multiple pages) and #1362 (project → top-right camera → no preview until Audio → Photo). Release target: 1.6.1.

## Findings and changes

- `CameraService.start()` declines startup while audio is busy, but `HomeView` did not observe busy completion in its camera task identity. A hosted real `HomeView`, actual AAC draft recovery and suspended save callback reproduced the missed retry. Observing `isBusy` now retries on completion. The regression uses a Debug-only camera start callback, so it verifies scheduling rather than hardware frames.
- The conditional landscape/portrait containers replaced the attached `CameraPreview.PreviewView` on every rotation. A hosted view resized through four transitions failed all four identity assertions. `CaptureLayout` now repositions the same header, preview and controls. The preview identity and portrait bounds assertions pass; an XCUITest verifies actual device rotation both on the home capture page and the project full-screen capture page.
- Separate tests of initial preview attachment, full-screen presentation and reopening passed without changing `CameraService`. The hypothesized synchronous visibility notification failure was not reproduced and was not patched.
- A first UI assertion immediately after rotation failed; waiting for the system orientation/layout to settle passed on unchanged production code. This transient test failure is not evidence of a persistent layout defect.

## Verification

Xcode 27.1; dedicated iPhone 17 Pro Max / iOS 26.5 simulator; synthetic workspace and audio only.

- Four focused hosted-view tests and the capture rotation UI test pass.
- Contract generation consistency, palette check, TypeScript typecheck and 169 TypeScript tests pass.
- Full iOS regression and additional cross-page rotation checks are recorded in the PR and task completion record when complete.

Local evidence: `/tmp/awd-1361/preview-rotation-red2.xcresult`, `/tmp/awd-camera-busy-1362-red.log`, `/tmp/awd-1361/camera-layout-green.xcresult`; screenshots exported to `/tmp/awd-1361/fixed-shots/`.

## Limits and device retest

The simulator has no physical camera. The known scheduling and preview replacement defects are verified; these tests do not establish that every reported physical-device layout issue has the same cause. The paired physical iPhone was unavailable for testing. Verify the distributed build on iPhone: open a project, tap the top-right camera without switching modes, rotate both ways and back, then visit project files, Settings and Library. Confirm a live preview and that controls remain correctly placed and usable. Camera authorization and actual photo/video output still require that device retest.
