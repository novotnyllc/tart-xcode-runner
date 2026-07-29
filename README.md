# Tart Xcode Runner

Codex and Claude Code plugin for running isolated commands, Xcode builds, and
XCUITests in reusable Tart macOS VMs. The powered-off `tart-xcui-base` VM is the golden image;
`tart-xcui-base-previous` is the rollback image.

Install in Claude Code (via the [novotnyllc marketplace](https://github.com/novotnyllc/marketplace)):

```sh
claude plugin marketplace add novotnyllc/marketplace
claude plugin install tart-xcode-runner@novotnyllc
```

```sh
RUNNER=skills/tart-xcode-runner/references/tart-runner
"$RUNNER" run -- /usr/bin/sw_vers
"$RUNNER" build --repo ~/dev/MyApp -- -scheme MyApp build
"$RUNNER" xcui-test --repo ~/dev/MyApp -- -scheme MyAppUITests test
```

See [`skills/tart-xcode-runner/SKILL.md`](skills/tart-xcode-runner/SKILL.md) for
installation, image acquisition, exact-beta Packer builds, and recovery.
Checked-in image configs are the reproducible golden-image contract used by
`prepare-image.zsh rebuild`: [`config/image-26.5.json`](config/image-26.5.json)
(stable, the default) and [`config/image-27-beta.json`](config/image-27-beta.json)
(exact macOS/Xcode 27 beta). A project can pin its own by committing
`.tart-xcode/image.json` at its repo root; pass it to `rebuild` or set
`TART_XCUI_IMAGE_CONFIG`. Each config's `buildStrategy` (`download`,
`upgrade`, or `packer`) chooses the construction path; every path validates
the candidate before promoting it and retains one rollback image.

VMs live in the Git-ignored `.tart/` directory by default; override that with
`TART_XCUI_TART_HOME=/absolute/path`. No setup path requires interactive input.
