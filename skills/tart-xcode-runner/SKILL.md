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
3. Pick the image config. Precedence, first match wins:

   1. A config checked into the project being tested: `.tart-xcode/image.json`
      at the repo root. Honor it without asking.
   2. The user explicitly asks for a beta or a specific OS/Xcode version.
   3. The project requires beta SDKs (deployment target or SDK newer than the
      current stable) → `"$PLUGIN_ROOT/config/image-27-beta.json"`.
   4. Otherwise the stable default: `"$PLUGIN_ROOT/config/image-26.5.json"`.

   Then build or update the golden image from it:

   ```sh
   "$IMAGE_BUILDER" rebuild "$CONFIG"
   ```

   With no argument, `rebuild` uses `TART_XCUI_IMAGE_CONFIG` or the stable
   default. To pin an image for a project, copy a shipped config into that
   repo as `.tart-xcode/image.json` and edit it — commit it so every machine
   reconstructs the same VM.

   Always run `rebuild` before considering any build: it validates the
   current golden image against the config and no-ops when it already
   matches — the image may already exist from a previous session. Follow the
   config's checked-in `buildStrategy`; do not pick a strategy yourself:

   - `download` (stable default): clone the pinned published OCI seed image
     and validate it. Fast; no local Xcode app needed.
   - `upgrade` (beta default): clone the pinned preconfigured seed, apply the
     pinned `InstallAssistant.pkg`, and install the configured host Xcode app,
     runtimes, CLI selection, license, Metal toolchain, and login settings —
     preserving guest agent, SSH, auto-login, and no-lock setup. Requires the
     beta Xcode app on the host at `xcodeApp` (Apple developer login needed to
     download it). There is no interactive Setup Assistant.

     The seed does NOT need to match the target macOS: `upgrade` exists
     precisely to build a newer macOS (a 27 beta) on top of the newest
     published seed (a 26.x image). "No published image for the target
     version" is the normal case `upgrade` solves, never a reason to fall
     back to `packer`.
   - `packer`: build from a restore IPSW. Slow (hours) and heavy; use only
     when no seed image of any version can boot the target at all — a new
     device family or a seed-incompatible major release, both rare. Never
     choose it just because the exact target version has no published seed.

   Direct commands also exist: `"$IMAGE_BUILDER" download OCI_IMAGE` promotes
   a published image (validated against the config first), and
   `"$IMAGE_BUILDER" packer --config CONFIG` runs the from-IPSW build; the
   packer path is unattended, bounded by `TART_XCUI_PACKER_TIMEOUT` (one hour
   default), and needs Packer and Go
   (`brew tap hashicorp/tap && brew install hashicorp/tap/packer go`).

All paths build a candidate, validate it, then replace the powered-off golden
base. Never delete the current base before candidate validation succeeds.
Repeat `--platform` to preload optional runtimes such as `tvOS`, `watchOS`, or
`visionOS`. iOS is the default when no platform is supplied.

Add runtimes later without rebuilding macOS or Xcode:

```sh
"$IMAGE_BUILDER" add-platform tvOS
```

This modifies a disposable clone and promotes it only after validation.
For a durable, reconstructible change, also add the platform to the active
config (the project's `.tart-xcode/image.json` if present) and run
`"$IMAGE_BUILDER" rebuild "$CONFIG"`.
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

The VM has no signing identities or provisioning profiles. Simulator builds
don't need them, but macOS (and device) targets do — append ad-hoc signing
overrides to the xcodebuild arguments for those:

```sh
CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS= \
AD_HOC_CODE_SIGNING_ALLOWED=YES
```

`CODE_SIGN_ENTITLEMENTS=` matters: any entitlement that needs a profile
(keychain access groups, app groups) otherwise fails the build even with
ad-hoc signing. Do not use `CODE_SIGNING_ALLOWED=NO` for UI tests — the
unsigned test runner hangs before connecting. Tests that genuinely require
those entitlements (data-protection keychain, auth flows) cannot pass in the
VM; exclude them with `-only-testing:`/`-skip-testing:` and say so in the
report rather than reporting a false failure. Projects often document which
suites need real signing — check their CI or verify scripts.

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

These stores are separate: a checkout and an installed plugin do not see
each other's VMs. Before building any image, run `"$RUNNER" doctor` — it
prints the active `TART_HOME` and whether the base VM exists. If the base is
"missing" but a golden image was built before, look for another store (a
plugin checkout's `.tart/`, or the Application Support path) and reuse it via
`TART_XCUI_DATA_HOME` instead of rebuilding for hours.
