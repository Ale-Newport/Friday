# Permissions

Friday asks for each permission only when a request needs it, explains why first, and keeps working with whatever you
allow. Revoke any of them in System Settings ▸ Privacy & Security.

| Permission | Needed for | When asked | Without it |
|---|---|---|---|
| **Microphone** | Wake word and voice commands | First launch (Settings ▸ General shows the state) | Chat and the keyboard shortcut still work; no voice input |
| **Speech Recognition** | On-device transcription (Apple) | First voice command | No transcription; typed commands only |
| **Automation (Apple Events)** per app | Music, Notes, Mail, Messages, Safari/Chrome tab reading, System Events (appearance), system volume | First command that targets that app | That app's tools report *permission required* with the Settings link |
| **Reminders** (full access) | `reminders.*` | First reminder command | Reminders tools disabled |
| **Calendars** (full access) | `calendar.*` | First calendar command | Calendar tools disabled |
| **Contacts** | `contacts.*`, resolving names | First contact lookup (off by default in engine settings) | Names are not resolved |
| **Accessibility** | `computer.*`: reading on-screen elements, clicking, typing, menus, arranging windows | First computer-control tool | Those tools explain how to enable it; everything else works |
| **Screen Recording** | `computer.screenshot`, `computer.describe_screen`, OCR | First “what is on my screen?” | Screen questions answer from Accessibility text only |
| **Login Items** approval + **Notifications** for *Friday Condition Agent* | `conditions.*`: rain checks delivered while Friday is closed | Settings ▸ Integrations ▸ Future conditions: *Enable future weather checks* registers the embedded agent (macOS asks under General ▸ Login Items & Extensions) and *Allow agent notifications…* shows its notification prompt | `conditions.schedule_rain` answers *needs setup*; `conditions.list` and `cancel` still work |

Not needed: Input Monitoring (the global shortcut uses `RegisterEventHotKey`), Full Disk Access (files are limited to
the folders you approve in Settings ▸ Integrations ▸ Files and Finder), Location Services (weather takes a city name,
or the default location in Settings ▸ Integrations ▸ Weather), any Chrome extension (the sidecar uses the DevTools
Protocol with its own profile, or attaches to your Chrome only after you allow remote debugging in Chrome).

Tools that need setup rather than a permission are configured in Settings ▸ Integrations: approved folders, approved
Shortcuts and the Focus Shortcut (`workflows.*`), the SearXNG endpoint (`research.search`), the default weather
location, the Clock shortcuts (`clock.*`, with the steps to build them) and the background condition agent.

Hardened runtime and sandbox: the app is **not** sandboxed (Apple Events, child processes, the local socket) and the
hardened runtime is off for ad-hoc builds so the speech libraries can load; set a real signing identity in
`Config/Local.xcconfig` to turn it on.
