# AGENTS.md

Run any command, build, or test in a disposable macOS VM (Tart), with guided
Developer ID signing setup. This repo *is* the plugin — the skill lives at
`skills/tart-xcode-runner/`, its executables at
`skills/tart-xcode-runner/references/`.

## Always

- UI tests, XCUITests, and simulator test runs go in the VM by default,
  without being asked: on the host they seize the user's display, keyboard,
  and focus. Run them on the host only if the user explicitly insists after
  being warned.
- Before operating the local test VM, read
  [`skills/tart-xcode-runner/SKILL.md`](skills/tart-xcode-runner/SKILL.md)
  and follow it — image selection, provisioning, recovery, and the Developer
  ID ceremony live there, not here.
- The plugin manifests sit at the repository root, not under `plugins/` —
  see [release coupling](docs/agents/release-coupling.md) before bumping a
  version.

## Verify

This repo has no CI — the check below is the gate. It stubs `security`,
`tart`, and friends, so it is safe on the host and needs no VM:

```sh
tests/test-setup-developer-id.zsh
tests/test-tart-runner-safety.zsh
```

Both manifests (`.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`)
must parse as JSON and carry the same `version`.
