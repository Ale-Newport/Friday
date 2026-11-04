# Third-party notice: code adapted from Atticus (atticus-mac)

`Sources/FridayComputer/` contains code adapted from **Atticus** (https://github.com/SaarthurR/atticus-mac,
file `Atticus.swift` at commit e337345), MIT License, Copyright (c) 2026 SaarthurR. Atticus declares its
`enum Hands` (lines 6727–8137) to adapt ideas and logic from **Plip** (https://github.com/hussainn7/plip-oss),
MIT License, Copyright (c) 2026 Hussain; everything below marked *(Hands)* therefore carries both notices.
Every Friday source file that contains adapted code starts with a one-line attribution comment pointing here.

All adapted code was rewritten for Swift 6 strict concurrency and Friday's module structure; names, signatures
and error handling differ from the originals. Line numbers refer to `Atticus.swift`.

## What was adapted

| Atticus function (lines) | Friday file / symbol |
|---|---|
| `axAttribute` (896–899) | `AXSupport.swift` — `AX.attribute` |
| `borrowPasteboard` (907–917) | `AccessibilityService.swift` — `AccessibilityService.borrowPasteboardCopy` (save → ⌘C → read → restore) |
| `MiniScreen.bounds` (2009–2011), `MiniScreen.visible` (2013–2016) | `CGWindows.swift` — `CGWindows.bounds`; `WindowGeometry.swift` — `WindowGeometry.isVisible` |
| `MiniScreen.windowTarget` (2022–2053) | `CGWindows.swift` — `CGWindows.isRealWindow`; `WindowManager.swift` — `WindowManager.axWindow(id:)` (AX window ↔ CG window matching by frame/title; simplified, no private window-number call) |
| `MiniScreen.open` (2194–2222) | `WindowManager.swift` — `WindowManager.focusWindow(id:)` (un-minimise, AXRaise, activate; the private `front()` call is not used) |
| `Onboarding.pane`, `perms`, `settings`, `grant` (4690, 4741–4746, 4791–4795, 4929–4961) | `ComputerPermissions.swift` — `ComputerPermissions.SettingsPane`, `accessibilityStatus/requestAccessibility`, `screenRecordingStatus/requestScreenRecording`, `openSettings(pane:)` |
| `--look` display capture excluding own windows (5054–5082) | `ScreenCaptureService.swift` — `ScreenCaptureService.screenshot(display:window:maxWidth:excludeOwnWindows:)` |
| `--text` window OCR (5085–5110) | `ScreenCaptureService.swift` — `ScreenCaptureService.ocr(_:)` |
| `Apps.check`, `Apps.statuses` (5373–5405) | `ComputerPermissions.swift` — `ComputerPermissions.automationCheck/automationStatus/requestAutomation` |
| `MeetingFrame.clamp` (5951–5957) | `WindowGeometry.swift` — `WindowGeometry.clamp` |
| `systemUI` (8141–8160) | `CGWindows.swift` — `CGWindows.systemUI` |
| *(Hands)* `Node.line`, `Map.description`, `Map.rich` (6729–6763) | `UITree.swift` — `UIElementSnapshot.line`, `UITree.describe`, `UITree.isRich` |
| *(Hands)* `secretPattern`, `riskyPattern`, `riskyLabel`, `secret`, `mask`, `normalized`, `rank` (6784–6815) | `AXSupport.swift` — `Safety` (Spanish vocabulary added) |
| *(Hands)* `keys`, `riskyKey` (6816–6838) | `KeyboardShortcut.swift` — `KeyboardShortcut.parse`, `KeyboardShortcut.isRisky` (Spanish and symbol aliases added) |
| *(Hands)* `attribute`, `element`, `children`, `frame`, `array`, `name` (6839–6885) | `AXSupport.swift` — `AX.attribute/element/elements/children/frame/name` |
| *(Hands)* `windowNumber` (6899–6907), frame-match fallback only | `CGWindows.swift` — `CGWindows.windowNumber(pid:frame:)` |
| *(Hands)* `capture` (7064–7119) | `AccessibilityService.swift` — `AccessibilityService.captureTree` |
| *(Hands)* `at` (7130–7136) | `AccessibilityService.swift` — `AccessibilityService.live(_:in:)` |
| *(Hands)* `visibleFrame` (7169–7178) | `AXSupport.swift` — `AX.visibleFrame` |
| *(Hands)* `actions`, `perform` (7228–7233) | `AXSupport.swift` — `AX.actions/perform` |
| *(Hands)* `menuItem`, `menu` (7234–7262) | `AccessibilityService.swift` — `AccessibilityService.menuItem/menuAction` |
| *(Hands)* `sendKeys` (7292–7301), public `CGEvent` path only | `AccessibilityService.swift` — `AccessibilityService.postShortcut` |
| *(Hands)* `windowAt`, `windowsAt` (7353–7363) | `CGWindows.swift` — `CGWindows.windowAt/windowsAt` |
| *(Hands)* `frontMouse` (7506–7530) | `AccessibilityService.swift` — `AccessibilityService.mouseClick` |
| *(Hands)* `frontWheel` (7531–7541) | `AccessibilityService.swift` — `AccessibilityService.scrollWheel` |
| *(Hands)* `contentMoved` (7566–7571), `scroll` method ladder (7576–7613) | `AccessibilityService.swift` — `AccessibilityService.contentMoved/scroll` |
| *(Hands)* `findText` (7615–7624), `resolve` ranking (7179–7227) — idea only | `UITree.swift` — `UITree.find`, `ElementMatcher` |
| *(Hands)* `stringValue`, `selectedRange` (7658–7666) | `AXSupport.swift` — `AX.stringValue/selectedRange` |
| *(Hands)* `fieldFocused` (7779–7786) | `AXSupport.swift` — `AX.fieldFocused` |
| *(Hands)* `typeText` (7787–7811) | `AccessibilityService.swift` — `AccessibilityService.typeText/setValue` (AX insertion, keystroke fallback; the clipboard-paste path was not reused) |

## What was deliberately not reused

Private or reverse-engineered APIs (`_AXUIElementGetWindow`, SkyLight `postKey`, `focusWithoutRaise`, `deliver`,
`mouse`, `wheel`, `MiniScreen.front`), `menuShortcut` (trycua/cua-derived), the `say` process, AppleScript
`display notification`, the shell-command tool framework, the HTML UI, telemetry.

## Licence texts

### Atticus — LICENSE

```
MIT License

Copyright (c) 2026 SaarthurR

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Plip — LICENSE-Plip (applies to the `enum Hands` adaptations marked above)

```
MIT License

Copyright (c) 2026 Hussain

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
