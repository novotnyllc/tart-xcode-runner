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
want a clean room: the default credential-free path does not touch your host
toolchain, caches, or keychain, and every run starts from the same pristine
image.

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

## Profile-backed macOS entitlements

The current runner does not automate host signing. Do not create or export a
Developer ID identity solely for this runner until the build/sign/return lane
below has been implemented and proven for the project.

The default VM path uses ad-hoc signing and needs no Apple credentials. A test
that exercises a restricted entitlement such as Keychain Sharing instead
needs a host-side [Developer ID Application
identity](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and a matching Developer ID provisioning profile.
Developer ID is for macOS distribution; it does not sign iOS apps.

This is a team signing identity, not a per-VM certificate. Developer ID
profiles use `ProvisionsAllDevices`, so the VM needs neither an Apple Account
nor device registration and does not consume one of the team's 100 development
device slots. One identity can sign build products from many apps and VM runs;
create one profile for each signed bundle ID that uses restricted entitlements.
A Developer ID Installer identity is unnecessary unless you also produce a
`.pkg`.

### Set up the first signing host

The guided helper fails closed on inaccessible Keychain state, opens the
human-only Apple steps, installs the exact requested certificate, proves its
private key can sign, and offers a round-trip-verified 1Password backup:

```sh
skills/tart-xcode-runner/references/setup-developer-id.zsh setup
```

Run it with `status` for a read-only preflight or `--help` for separate
enrollment, signing-probe, 1Password storage, and restore commands. The guided
and mutating commands require an attached terminal. When an agent invokes one,
it must keep the whole command in one persistent PTY or tmux session so
Keychain and 1Password authorization prompts remain available. If `status`
cannot inspect the Keychain, authorize it on the host and retry; do not assume
the identity is absent.

1. Inventory the team's existing Developer ID Application certificates before
   creating another; a team can have up to five. Reuse one only when the host
   is already approved for release signing. Otherwise, consider a dedicated
   VM-test certificate if the extra active key and certificate slot fit the
   team's custody policy.
2. On the intended signing host, use Keychain Access **Certificate Assistant >
   Request a Certificate From a Certificate Authority** to create the CSR.
   This creates the private key on that host. Have the Account Holder create
   the Developer ID Application certificate from that CSR, download the
   `.cer` to the same host, then give its path to the still-running helper.
   Do not open it manually: the helper imports the validated certificate,
   checks its exact fingerprint/private-key pairing, and proves signing access.
   The `.cer` alone cannot sign.
3. In Certificates, Identifiers & Profiles, register an explicit App ID and
   enable the required Developer-ID-supported capabilities. Create a
   **Distribution > Developer ID** profile selecting that App ID and
   certificate, then download the profile to the signing host. Repeat only
   for other entitlement-bearing bundle IDs.
4. Run the helper's `probe` command. It binds the check to the certificate's
   exact fingerprint, signs a disposable executable with the login Keychain,
   and verifies the result strictly. Configure the host Keychain according to
   team policy and approve only the actual signing process. Do not grant
   private-key access to all applications.

Keep the private key on signing hosts. Never put it, a `.p12`, its password,
Apple credentials, or an API key in a Tart VM, golden image, repository,
guest share, or test artifact.

### Add another signing host

Choose one of these models:

- **Share the identity through 1Password.** In Keychain Access **My
  Certificates**, export the identity as a strongly encrypted `.p12`; this
  file contains both the certificate and private key. The helper's `store-p12`
  command validates the archive before upload and stores it with its concealed
  export password in one item in an explicitly selected account and restricted
  vault. It then downloads and validates both before reporting success. Record
  the printed item ID and use `restore-p12` on the other host; restore validates
  the archive before import, requires the exact fingerprint afterward, proves
  signing access, and removes its temporary copy. Because both factors are in
  one item, that restricted vault is the security boundary. Use separately
  controlled storage instead when policy requires independent protection.
  Sharing uses no additional certificate slot, but compromise or revocation
  affects every host using that key. See [1Password's file storage
  guidance](https://support.1password.com/files/).
- **Use a separate identity.** Create the CSR on the other host and issue
  another Developer ID Application certificate. This consumes another of the
  team's five slots and needs a profile that authorizes that certificate, but
  keeps the private keys and revocation boundary separate.

1Password is one approved backup and transfer mechanism; `codesign` uses the
identity after it has been imported into the host Keychain. Do not download
the `.p12` for every test run or copy it into a disposable VM.

### Test flow

The lane to implement and prove is:

1. Run `xcodebuild build-for-testing` in a disposable guest while preserving
   enough build metadata to reconstruct each product's fully expanded
   entitlements.
2. Move the build products to the host, embed the matching profile at
   `<bundle>/Contents/embedded.provisionprofile` for every product that needs
   one, and sign all nested code inside-out with the Developer ID Application
   identity and each product's explicit entitlements. Never use
   `codesign --deep`.
3. Return the signed products to the same guest clone and run
   `xcodebuild test-without-building`.

The existing guest helper clears `CODE_SIGN_ENTITLEMENTS`, so simply embedding
a profile and re-signing the current output is insufficient. The future lane
must preserve or reconstruct the expanded entitlements and pass them explicitly
when signing.

Before relying on it, prove one real entitlement-dependent XCTest end to end:
verify strict signatures, compare `codesign -d --entitlements :-` output with
the embedded profile, confirm `ProvisionsAllDevices`, and exercise the
protected operation through an app relaunch.

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
input during normal runs; Developer ID enrollment and the first Keychain
authorization are deliberate one-time exceptions.

## License

MIT
