# The standalone .exe

## What exists now (version 1.1.0)

`CodHQ-Setup.exe` is a small Windows launcher (about 0.5 MB) with `install.ps1`
embedded:

- **Source:** [tools/exe/Launcher.cs](../tools/exe/Launcher.cs). It is built by
  [tools/Build-Exe.ps1](../tools/Build-Exe.ps1) with the .NET Framework 4 C# compiler
  that every Windows 10/11 has. There is no SDK, no ps2exe and nothing to install.
- **Startup:** it writes the embedded script to
  `%LOCALAPPDATA%\CallOfDutyHQ-SetupUtility\app\install-<hash>.ps1`. The copy is
  rewritten only when the version changes, and older copies are removed. It then
  starts Windows PowerShell 5.1 with `-STA -File`, without a console window, exactly
  as `irm ... | iex` ends up running the script.
- **Arguments:** passed through, so `-Sandbox`, `-GameFolder` and the administrator
  hand-off work as with the script.
- **Version and icon:** the version comes from `$AppVersion`, and the icon is drawn
  by [tools/exe/New-AppIcon.ps1](../tools/exe/New-AppIcon.ps1).
- **Tests:** [tests/Test-Exe.ps1](../tests/Test-Exe.ps1) checks the version, the
  icon, that the written script is `install.ps1` byte for byte, and the argument
  quoting. With `-Launch` it also opens the real window from the exe in sandbox
  mode.
- **CI:** [build-exe.yml](../.github/workflows/build-exe.yml) builds and checks it on
  every change. The first build of each new version is published as the pre-release
  `app-v<version>`.
- **Updates:** **Check all for updates** compares the running version with the one
  on `main`, and tells exe users to download the new exe.

Building locally:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Exe.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Exe.ps1 -Launch
```

## Known limits

- **It is not code-signed.** SmartScreen shows "Windows protected your PC" on the
  first run (More info > Run anyway), and some antivirus products flag unsigned
  launchers that start PowerShell. Signing removes most of that.
- **It still needs Windows PowerShell 5.1**, which every Windows 10/11 has.
- **The window is the script's WPF window**, so it looks and behaves exactly like
  the script.

## Next steps, in order

1. **Code signing.** Buy an OV or EV code-signing certificate (or use Azure Trusted
   Signing), sign the exe in CI with `signtool sign /tr <timestamp> /td sha256 /fd
   sha256`, and keep the certificate in a GitHub secret. EV certificates earn
   SmartScreen reputation immediately; OV builds it up over downloads.
2. **Self-update.** On start, the exe checks the newest `app-v*` release with GitHub's
   API, verifies its SHA-256 digest, downloads it next to itself, and swaps on the next
   start (rename the running exe to `.old`, move the new one in, delete `.old` later).
3. **Installer and shortcuts.** An optional per-user install to
   `%LOCALAPPDATA%\Programs\CodHQ`, with a Start menu shortcut and an uninstall entry
   (Inno Setup, or WiX with a signed MSI).
4. **Native UI, when Tier III starts.** The server browser, accounts, friends and
   community need a real application. The plan:
   - Port the WPF window from the script's XAML into a .NET 8 WPF app (the XAML moves
     over almost as it is).
   - Move the PowerShell functions into C# services one area at a time (downloads,
     catalogue, clients, Steam), each with tests.
   - Keep the script working the whole time; the app can call it for the parts not
     yet ported.
   - Publish self-contained single-file builds per architecture, signed.
