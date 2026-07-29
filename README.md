# Tart Xcode Runner

Codex plugin for running isolated commands, Xcode builds, and XCUITests in
reusable Tart macOS VMs. The powered-off `tart-xcui-base` VM is the golden image;
`tart-xcui-base-previous` is the rollback image.

```sh
RUNNER=skills/tart-xcode-runner/references/tart-runner
"$RUNNER" run -- /usr/bin/sw_vers
"$RUNNER" build --repo ~/dev/MyApp -- -scheme MyApp build
"$RUNNER" xcui-test --repo ~/dev/MyApp -- -scheme MyAppUITests test
```

See [`skills/tart-xcode-runner/SKILL.md`](skills/tart-xcode-runner/SKILL.md) for
installation, image acquisition, exact-beta Packer builds, and recovery.
The checked-in [`config/image.json`](config/image.json) is the reproducible
golden-image contract used by `prepare-image.zsh rebuild`. The default rebuild
follows its checked-in `buildStrategy`, installs Xcode and configured runtimes,
validates the exact builds, then promotes the candidate while retaining one
rollback image. This contract upgrades the pinned, preconfigured Tahoe OCI
image by default; the from-IPSW Packer path remains available as a fallback.

VMs live in the Git-ignored `.tart/` directory by default; override that with
`TART_XCUI_TART_HOME=/absolute/path`. No setup path requires interactive input.
