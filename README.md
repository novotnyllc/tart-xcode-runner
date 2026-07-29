# Tart Xcode Runner

A Codex and Claude Code plugin that runs commands, Xcode builds, and XCUITests
in disposable [Tart](https://tart.run) macOS VMs instead of on your Mac.

## Why

UI tests seize your machine. Run XCUITests on the host and the simulator (or
worse, a macOS UI test) grabs your display, keyboard, and focus while you're
trying to work. Agents make this worse: an AI coding assistant that "just runs
the tests" takes over your screen mid-task.

This plugin gives your agent a VM instead. Once installed, asking Claude or
Codex to run tests routes UI and simulator work into an isolated VM
automatically — no prompting, no host takeover. Builds run there too when you
want a clean room: nothing touches your host toolchain, caches, or keychain,
and every run starts from the same pristine image.

## How it works

- A powered-off golden image (`tart-xcui-base`) holds macOS + Xcode, fully
  provisioned: license accepted, first-launch done, simulator runtimes and
  Metal toolchain installed, auto-login enabled, screen lock and sleep off.
- Every run clones the golden image into a throwaway VM, mounts your checkout
  read-only, copies it to guest APFS, runs the work, exports logs and the
  `.xcresult` bundle to a results directory on the host, then deletes the
  clone. The golden image is never mutated by a run.
- Image changes (updates, new simulator platforms) build a *candidate* clone,
  validate it against a checked-in config, and only then promote it — keeping
  the previous image for one-command rollback. An interrupted or broken run
  can always be cleared with `reset` without touching the base.
- Runs can execute in parallel, each in its own clone; image changes are
  exclusive. Every run is bounded by a watchdog timeout, so a hung test
  can't wedge the machine. Set `TART_XCUI_BASE_VM` to keep multiple golden
  images (say macOS 26 stable and the 27 beta) side by side.

## Install

Claude Code (via the [novotnyllc marketplace](https://github.com/novotnyllc/marketplace)):

```sh
claude plugin marketplace add novotnyllc/marketplace
claude plugin install tart-xcode-runner@novotnyllc
```

Codex:

```sh
codex plugin marketplace add novotnyllc/marketplace
codex plugin add tart-xcode-runner --marketplace novotnyllc
```

Requirements: Apple Silicon Mac and [Tart](https://tart.run)
(`brew tap openai/tools && brew trust --tap openai/tools && brew install openai/tools/tart`).
The first image build downloads ~25 GB; VMs need disk space (200 GB
allocated, thin-provisioned).

After installing, just ask your agent to run your tests — the skill triggers
on its own for UI, XCUITest, and simulator work, and provisions the VM with
whatever simulator platforms your project needs. Or invoke it explicitly:
"use tart-xcode-runner to run MyAppUITests".

## Direct CLI use

Everything the agent does is a plain zsh script you can run yourself:

```sh
RUNNER=skills/tart-xcode-runner/references/tart-runner

"$RUNNER" doctor                                    # check host readiness
"$RUNNER" run -- /usr/bin/sw_vers                   # any command in a fresh VM
"$RUNNER" build --repo ~/dev/MyApp -- -scheme MyApp build
"$RUNNER" xcui-test --repo ~/dev/MyApp -- -scheme MyAppUITests test
"$RUNNER" add-platform tvOS                         # add a simulator runtime
"$RUNNER" reset                                     # clear disposable state
"$RUNNER" clean --results 14                        # reclaim disk space
"$RUNNER" rollback                                  # restore previous image
```

Each run prints its results directory containing `xcodebuild.log` (or
`command.log`), `Result.xcresult`, and the exit status.

## Image configs

Golden images are reconstructed from checked-in JSON contracts, so any machine
can rebuild the exact same VM:

- [`config/image-26.5.json`](config/image-26.5.json) — current stable macOS +
  Xcode from the published Tart image. The default; fast to set up, no local
  Xcode download needed.
- [`config/image-27-beta.json`](config/image-27-beta.json) — exact macOS 27 /
  Xcode 27 beta builds, pinned by version, build number, and installer
  checksum. Requires the beta Xcode app on the host.

A project can pin its own environment by committing `.tart-xcode/image.json`
at its repo root — the skill uses it automatically, and teammates (and their
agents) reconstruct the identical VM. `prepare-image.zsh rebuild [CONFIG]`
does the work; it no-ops when the current image already validates, and each
config's `buildStrategy` (`download`, `upgrade`, or `packer`-from-IPSW)
chooses how the image is constructed.

See [`skills/tart-xcode-runner/SKILL.md`](skills/tart-xcode-runner/SKILL.md)
for the full agent-facing instructions: setup, image selection rules,
provisioning, and recovery.

## Storage

From a source checkout, VM disks and results live in Git-ignored directories
(`.tart/`, `results/`, `vm-share/`, `.state/`). From an installed plugin,
they live under `~/Library/Application Support/Tart Xcode Runner/` and survive
plugin upgrades. Override with `TART_XCUI_DATA_HOME` (everything) or
`TART_XCUI_TART_HOME` (VM disks only). No setup path requires interactive
input.

## License

MIT
