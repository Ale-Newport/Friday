# Installing Friday from the download

Requirements: a Mac with Apple Silicon (M1 or newer) running **macOS 26 or newer**.

## 1. Check the download (recommended)

Every release lists a SHA-256 for the zip and a build-provenance attestation that proves it was built by this
repository's public GitHub Actions workflow from the tagged source:

```bash
shasum -a 256 ~/Downloads/Friday-*-macos-arm64.zip          # compare with the .sha256 file on the release page
gh attestation verify ~/Downloads/Friday-*-macos-arm64.zip --repo Ale-Newport/Friday   # optional, needs the GitHub CLI
```

## 2. Install

1. Unzip the download and drag **Friday.app** to **Applications**.
2. Open Friday. macOS says it *cannot verify that Friday is free of malware*: the app is **not notarized** (the project
   has no paid Apple Developer ID), only ad-hoc signed. Choose **Done**, then open **System Settings ▸ Privacy &
   Security**, scroll down to the message about Friday and click **Open Anyway**, then confirm with your password or
   Touch ID. You only do this once.

   Prefer the terminal? After checking the SHA-256 above:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Friday.app && open /Applications/Friday.app
   ```

3. Allow the **Microphone** when asked, then say **“Jarvis”** — or click the menu-bar icon and type.

The first time you use something, macOS asks for that permission (Reminders, Calendar, Contacts, Automation for Music
or Notes, Accessibility for computer control, Screen Recording for “what's on my screen?”). See
[PERMISSIONS.md](PERMISSIONS.md) for what each one is for.

**Switching from a build you made yourself?** The download is signed differently, so macOS treats it as a new app:
it asks for the microphone and other permissions again, and the first time Friday reads a key it saved before
(your ChatGPT sign-in, an API key), the Keychain asks whether *Friday* may use it — choose **Always Allow**, or sign
in again from Settings.

## 3. Connect a model (optional)

Everyday commands (time, maths, unit conversion, opening apps, music, reminders…) work without any model. For open
questions and multi-step tasks, open **Settings ▸ Intelligence** and either **Continue with ChatGPT**, add an OpenAI
API key, or run [Ollama](https://ollama.com) or LM Studio — Friday finds them on this Mac.

The browser agent's routing model (Laya, ≈ 810 MB) downloads the first time you use the browser agent.

## What is in the download

* `Friday.app` — the assistant, `fridayctl` (in `Contents/Helpers`), the condition agent, the wake-word and speech
  models, and the browser sidecar.
* `Licenses/` — Friday's MIT licence and every third-party notice. The bundle contains components under the GPL-3.0
  (espeak-ng, piper-phonemize, inside the sherpa-onnx library), the LGPL-3.0 (edge-tts) and CC BY-NC-SA 4.0 (the
  offline Spanish voice “miro”, free for non-commercial use); their source is attached to the same release.

## Uninstall

Quit Friday, delete `/Applications/Friday.app`, and optionally `~/Library/Application Support/Friday`. Saved keys are
in the Keychain under `com.alejandro.friday`.

---

## Instalación (español)

Necesitas un Mac con Apple Silicon y **macOS 26 o posterior**.

1. Descomprime la descarga y arrastra **Friday.app** a **Aplicaciones**.
2. Al abrirla, macOS avisa de que *no puede verificar* la app: no está notarizada (el proyecto no tiene un Developer
   ID de pago), solo firmada ad hoc. Pulsa **Aceptar**, abre **Ajustes del Sistema ▸ Privacidad y seguridad** y pulsa
   **Abrir igualmente** junto al aviso de Friday. Solo hace falta una vez. (Desde el Terminal:
   `xattr -dr com.apple.quarantine /Applications/Friday.app`.)
3. Permite el **micrófono** y di **«Jarvis»**, o escribe desde el icono de la barra de menús.

Comprueba antes el SHA-256 del zip con el que aparece en la página de la versión.
