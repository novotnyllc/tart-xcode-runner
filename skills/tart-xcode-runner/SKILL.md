---
name: tart-xcode-runner
description: Run any command, build, or test in a disposable macOS virtual machine (Tart). Use whenever the user wants work run in a VM, sandbox, container, clean room, or fresh/isolated/ephemeral/disposable environment, off-host, "not on my machine", or without polluting their system — especially xcodebuild, Xcode builds, unit tests, UI tests, XCUITests, iOS/macOS/simulator work, or trying something risky safely. ALWAYS use this by default for UI tests, XCUITests, and simulator-based test runs — even when the user doesn't mention a VM — because host UI automation steals their screen, keyboard, and focus. Also use to prepare, update, reset, roll back, or fetch logs and xcresult bundles from the test VM.
---

# Tart Xcode Runner

UI tests, XCUITests, and simulator test runs go in the VM by default, without
being asked: on the host they seize the user's display, keyboard, and focus
while they work. Run them on the host only if the user explicitly insists
after being warned.

Installed plugins expose their root as `CLAUDE_PLUGIN_ROOT` (Claude Code) or
`CODEX_PLUGIN_ROOT` (Codex); from a source checkout, run commands at the
repository root instead. Set:

```sh
PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-.}}
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

### Optional Developer ID setup

The current runner does not automate a Developer ID build/sign/return lane.
Setup alone does not make entitlement-dependent tests pass. Keep using the
credential-free ad-hoc path unless the project genuinely exercises a restricted
entitlement such as Keychain Sharing.

Before implementing that lane, follow
[Profile-backed entitlements](../../README.md#profile-backed-entitlements).
It is the canonical operator procedure for CSR and profile creation, 1Password
transfer, multiple hosts, Keychain readiness, and certificate-slot tradeoffs.
A Developer ID identity stays on approved signing hosts: never put a private
key, `.p12`, password, Apple credential, or API key in the repository, golden
image, guest share, VM, or test artifacts. Do not register the VM or sign an
Apple Account into the guest.

The implementation must preserve or reconstruct every product's fully expanded
entitlements, embed each matching profile, sign nested code inside-out without
`codesign --deep`, and return the products to the same guest for
`test-without-building`. Prove a real protected operation through app relaunch,
including strict signature, entitlement, and `ProvisionsAllDevices` checks,
before reporting the lane as supported.

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

Signing is handled automatically on the credential-free path: the VM has no
signing identities, so when no `CODE_SIGN*`, `DEVELOPMENT_TEAM`, or
`PROVISIONING_PROFILE*` argument is supplied, the guest applies ad-hoc manual
signing with entitlements dropped (verified: macOS UI tests pass with no
signing arguments). Passing signing arguments only disables that fallback; it
does not expose host identities to the guest. Never pass
`CODE_SIGNING_ALLOWED=NO` for UI tests — the unsigned test runner hangs before
connecting.

Ad-hoc signing cannot authorize profile-backed entitlements. Until the
host-signing round-trip above is implemented and proven for the project,
exclude those tests with `-only-testing:`/`-skip-testing:` and say so in the
report rather than reporting a false failure. Never copy a Developer ID
identity into the VM as a shortcut.

Report the printed result directory and exit status. Inspect `command.log` or
`xcodebuild.log`; use `xcrun xcresulttool` against `Result.xcresult` for
structured failures. Never make the source share writable or build on VirtioFS.

## Recover or update

- Run `"$RUNNER" reset` after an interrupted invocation. It removes only the
  disposable clone and preserves the powered-off base.
- Run `"$RUNNER" rollback` to swap the golden base with the previous validated
  image. Each promotion preserves one rollback image (`<base>-previous`).
- Set `TART_XCUI_KEEP_FAILED=1` for one run when interactive inspection is
  necessary; reset it afterward.
- Run `"$IMAGE_BUILDER" download OCI_IMAGE` to validate and promote a different
  published image.
- Run `"$RUNNER" smoke` after changing the runner, guest scripts, Tart, or
  the base image.

Runs may execute in parallel: each gets its own disposable clone, and the
host lock covers only the brief clone step. Budget CPU and RAM — each VM
takes its configured share. Image operations (`prepare`, `add-*`, `reset`,
`rollback`, rebuilds) are exclusive and refuse to start while runs are
active; retry them after the runs finish.

## Multiple golden images

`TART_XCUI_BASE_VM` selects the golden image; candidate, previous, and
work VM names derive from it. Keep one base per image config when projects
need different OS or Xcode versions:

```sh
export TART_XCUI_BASE_VM=tart-xcui-base-26   # this project targets macOS 26
"$IMAGE_BUILDER" rebuild "$PLUGIN_ROOT/config/image-26.5.json"
"$RUNNER" xcui-test --repo /path/to/repo -- -scheme App test
```

Another project can use `TART_XCUI_BASE_VM=tart-xcui-base-27` with the beta
config; both images coexist in the same store, each with its own rollback.
Pair the variable with the project's pinned `.tart-xcode/image.json` so the
same shell sets both. The default base (`tart-xcui-base`) stays for
single-image setups.

## Cleanup

Disk grows in four places: OCI/IPSW caches under `TART_HOME/cache` (tens of
GB), the rollback image (`<base>-previous`, as big as the base), installer
and Xcode archives in `vm-share/cache`, and per-run logs/results. Reclaim
space with:

```sh
"$RUNNER" clean                 # stale VMs, state logs, caches unused 30 days
"$RUNNER" clean --results 14    # also drop result bundles older than 14 days
"$RUNNER" clean --images        # also drop the rollback image and archives
```

`clean` is exclusive (refuses while runs are active) and never touches the
golden base. `--images` trades safety for space: rollback becomes
unavailable until the next promotion, and a future rebuild re-downloads
installers. Suggest `clean` to the user when `doctor` shows the disk running
low; ask before using `--images`.

Superseded versions age out on their own where it's safe: promoting a new
image auto-deletes older pinned installers and Xcode archives (re-downloadable,
keyed by build), and each base keeps exactly one rollback — promoting beta 5
retires beta 4's rollback. Whole golden images are never auto-deleted: when
`clean` lists a base VM whose last access is old (a stable base no project
uses anymore), ask the user before removing it and its `-previous` with
`tart delete`.

## Configuration reference

All knobs are environment variables; defaults in parentheses:

- `TART_XCUI_DATA_HOME` — root for all mutable data (checkout, or
  `~/Library/Application Support/Tart Xcode Runner`)
- `TART_XCUI_TART_HOME` — VM disk storage only (`$DATA_HOME/.tart`)
- `TART_XCUI_RESULTS` — result bundles (`$DATA_HOME/results`)
- `TART_XCUI_BASE_VM` — golden image to use (`tart-xcui-base`); derived:
  `<base>-candidate`, `<base>-previous`, `<base>-packed`
- `TART_XCUI_IMAGE_CONFIG` — default config for `rebuild`
  (`config/image-26.5.json`)
- `TART_XCUI_CPU`, `TART_XCUI_MEMORY` (MB), `TART_XCUI_DISK_SIZE` (GB) —
  resources applied by `prepare` when the config doesn't set them
  (8 / 24576 / 150); config values win on rebuilds
- `TART_XCUI_RUN_TIMEOUT` — per-run watchdog seconds (7200)
- `TART_XCUI_READY_TIMEOUT` — VM boot wait seconds (300)
- `TART_XCUI_PACKER_TIMEOUT`, `TART_XCUI_UPGRADE_TIMEOUT` — image build
  ceilings (3600 / 7200)
- `TART_XCUI_KEEP_FAILED=1` — retain a failed run's VM for inspection
- `TART_XCUI_GUEST_PASSWORD` — guest admin password (`admin`)
- `TART_XCUI_IMAGE` — OCI image for a bare `prepare` (pinned 26.5 digest)
- `TART_XCUI_RUNS_WAIT` — how long image operations wait for active runs
  to drain before giving up (1800)

## Storage

From a source checkout, VM disks and mutable data stay in its Git-ignored
`.tart/`, `results/`, `vm-share/`, and `.state/` directories. From an installed
plugin, they stay across plugin upgrades under
`~/Library/Application Support/Tart Xcode Runner/`. Set
`TART_XCUI_DATA_HOME` to move all mutable data together, or
`TART_XCUI_TART_HOME` to move only Tart's VM storage.

Claude Code and Codex installs both default to the same Application Support
store, so they share golden images. A source checkout is the exception —
its store is separate from any installed plugin's. Before building any image, run `"$RUNNER" doctor` — it
prints the active `TART_HOME` and whether the base VM exists. If the base is
"missing" but a golden image was built before, look for another store (a
plugin checkout's `.tart/`, or the Application Support path) and reuse it via
`TART_XCUI_DATA_HOME` instead of rebuilding for hours.
