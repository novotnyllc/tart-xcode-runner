---
name: tart-xcode-runner
description: Run any command, build, or test in a disposable macOS virtual machine (Tart). Use whenever the user wants work run in a VM, sandbox, container, clean room, or fresh/isolated/ephemeral/disposable environment, off-host, "not on my machine", or without polluting their system — especially xcodebuild, Xcode builds, unit tests, UI tests, XCUITests, iOS/macOS/simulator work, or trying something risky safely. ALWAYS use this by default for UI tests, XCUITests, and simulator-based test runs — even when the user doesn't mention a VM — because host UI automation steals their screen, keyboard, and focus. Also use to prepare, update, reset, roll back, or fetch logs and xcresult bundles from the test VM.
---

# Tart Xcode Runner

UI tests, XCUITests, and simulator test runs go in the VM by default, without
being asked: on the host they seize the user's display, keyboard, and focus
while they work. Run them on the host only if the user explicitly insists
after being warned.

`CLAUDE_PLUGIN_ROOT` is set when this runs as an installed Claude Code plugin;
from a source checkout, run commands at the repository root instead. Set:

```sh
PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-.}
RUNNER=$PLUGIN_ROOT/skills/tart-xcode-runner/references/tart-runner
IMAGE_BUILDER=$PLUGIN_ROOT/skills/tart-xcode-runner/references/prepare-image.zsh
```

## Setup

1. Install and trust OpenAI's Homebrew tap:

   ```sh
   brew tap openai/tools
   brew trust --tap openai/tools
   brew install openai/tools/tart
   ```

2. Run `"$RUNNER" doctor`. If the execution sandbox cannot inspect the login
   keychain or start Virtualization.framework, request host authorization for
   the runner. Never fall back to running UI tests on the host.
3. Choose one image path:

   - Reconstruct or update the repository-pinned image (recommended):

     ```sh
     "$IMAGE_BUILDER" rebuild
     ```

     This reads `config/image.json`, skips the build when the current golden
     image passes exact runtime validation, and safely updates when it changes.
     `buildStrategy` chooses the checked-in construction path. The default
     `upgrade` path clones the pinned, preconfigured Tahoe Xcode image and
     applies the pinned `InstallAssistant.pkg`, preserving its guest agent,
     SSH, account, auto-login, and no-lock setup. Use `packer` only when a
     compatible published seed is unavailable. Both paths install the
     configured host Xcode app, runtimes, CLI selection, license, Metal
     toolchain, and login settings before promotion. There is no interactive
     Setup Assistant.

   - Published OCI image:

     ```sh
     "$IMAGE_BUILDER" download OCI_IMAGE
     ```

     The downloaded candidate must satisfy `config/image.json` before it can
     replace the golden base.

   - Exact macOS/Xcode beta with a restore IPSW and local Xcode app:

     ```sh
     "$IMAGE_BUILDER" packer --config "$PLUGIN_ROOT/config/image.json"
     ```

     This from-IPSW path is also unattended and bounded by
     `TART_XCUI_PACKER_TIMEOUT` (one hour by default). It requires Packer and
     Go; install them with:

     ```sh
     brew tap hashicorp/tap
     brew install hashicorp/tap/packer
     brew install go
     ```

     The config supplies the IPSW, exact builds, local Xcode app, SDKs,
     runtimes, and VM resources. Apple beta Xcode downloads require an Apple
     developer login, so place the configured app at `xcodeApp` before running
     either reconstruction path.

All paths build a candidate, validate it, then replace the powered-off golden
base. Never delete the current base before candidate validation succeeds.
Repeat `--platform` to preload optional runtimes such as `tvOS`, `watchOS`, or
`visionOS`. iOS is the default when no platform is supplied.

Add runtimes later without rebuilding macOS or Xcode:

```sh
"$IMAGE_BUILDER" add-platform tvOS
```

This modifies a disposable clone and promotes it only after validation.
For a durable, reconstructible change, also add the platform to
`config/image.json` and run `"$IMAGE_BUILDER" rebuild`.
The golden base also selects Xcode's CLI tools, completes first-launch tasks,
accepts the license, installs the Metal toolchain, enables auto-login, and
disables sleep, screensavers, and screen locking.

## Match the VM to the project

Before running project work, detect what the project needs and provision the
VM to match — never ask the user to do this manually:

1. Inspect the checkout on the host: `SDKROOT`, destinations, and platform
   names in `*.pbxproj`, schemes, and `Package.swift`
   (`appletvos`/`tvOS` → tvOS, `watchos` → watchOS, `xros`/`visionOS` →
   visionOS; Metal shader compilation → MetalToolchain). iOS and macOS are
   always present in the base image.
2. If extra platforms are needed, check what the VM already has:

   ```sh
   "$RUNNER" run -- /usr/bin/xcrun simctl list runtimes available
   ```

3. Install anything missing, then proceed:

   ```sh
   "$RUNNER" add-platform tvOS
   "$RUNNER" add-component MetalToolchain
   ```

If a run still fails with a missing-runtime or missing-SDK error, install the
named platform the same way and retry once. Dependencies fetched by the build
itself (SwiftPM, CocoaPods via `--repo` copy) need no VM changes — they
resolve inside the disposable clone.

## Run

Run an arbitrary command in a disposable clone:

```sh
"$RUNNER" run -- /usr/bin/sw_vers
"$RUNNER" run --repo /absolute/path/to/repo -- /bin/zsh -lc 'make check'
```

`--repo` mounts the checkout read-only, copies it to guest APFS, and runs from
that copy. The command receives `TART_SOURCE` and `TART_ARTIFACTS`.

Run an Xcode build:

```sh
"$RUNNER" build --repo /absolute/path/to/repo -- \
  -workspace App.xcworkspace -scheme App build
```

Run an XCUITest:

```sh
"$RUNNER" xcui-test --repo /absolute/path/to/repo -- \
  -workspace App.xcworkspace \
  -scheme AppUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  test
```

Omit `-destination` to use the first available iPhone simulator. Pass an
explicit destination for macOS tests or when device choice matters.

Report the printed result directory and exit status. Inspect `command.log` or
`xcodebuild.log`; use `xcrun xcresulttool` against `Result.xcresult` for
structured failures. Never make the source share writable or build on VirtioFS.

## Recover or update

- Run `"$RUNNER" reset` after an interrupted invocation. It removes only the
  disposable clone and preserves the powered-off base.
- Run `"$RUNNER" rollback` to swap the golden base with the previous validated
  image. Each promotion preserves `tart-xcui-base-previous`.
- Set `TART_XCUI_KEEP_FAILED=1` for one run when interactive inspection is
  necessary; reset it afterward.
- Run `"$IMAGE_BUILDER" download OCI_IMAGE` to validate and promote a different
  published image.
- Run `"$RUNNER" smoke` after changing the runner, guest scripts, Tart, or
  the base image.

Use one invocation at a time. The wrapper enforces this with a host lock.

## Storage

From a source checkout, VM disks and mutable data stay in its Git-ignored
`.tart/`, `results/`, `vm-share/`, and `.state/` directories. From an installed
plugin, they stay across plugin upgrades under
`~/Library/Application Support/Tart Xcode Runner/`. Set
`TART_XCUI_DATA_HOME` to move all mutable data together, or
`TART_XCUI_TART_HOME` to move only Tart's VM storage.
