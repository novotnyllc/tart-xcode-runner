# Release coupling

This repo is the plugin. Unlike the sibling plugin repos, there is no
`plugins/<name>/` subdirectory — the manifests live at the repository root:

- `.claude-plugin/plugin.json`
- `.codex-plugin/plugin.json`

Bump both in lockstep. The Codex manifest additionally carries the
`interface` block (display name, capabilities, default prompts, icons); keep
`name`, `version`, and `description` identical between the two.

## The `path: "."` quirk

Because the plugin is the repository root, the marketplace entries do not
look like the others:

- `.agents/plugins/plugin-versions.json` records `"path": "."` for this
  plugin, where siblings record `plugins/<name>`.
- `.agents/plugins/marketplace.json` uses a `url` source tracking
  `ref: "main"`, and `.claude-plugin/marketplace.json` uses a `github`
  source — **neither is sha-pinned**.

Consequence: `scripts/repin tart-xcode-runner …` in the marketplace repo will
refuse this entry ("is not sha-pinned") because there is no `sha` field to
update. A version change here reaches the fleet on the next `main` fetch;
only the `version` in the marketplace manifests and `plugin-versions.json`
needs a manual bump, and `scripts/repin check` will flag it if you forget.

Never treat an installed plugin cache as the source repository.
