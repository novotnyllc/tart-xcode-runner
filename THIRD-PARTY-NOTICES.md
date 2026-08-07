# Third-party notices

tart-xcode-runner incorporates the material below. Our own code is MIT
([`LICENSE`](LICENSE)); the entries here carry their upstream licenses.

Tools this project merely *invokes* — Tart, Packer, Xcode, Homebrew — are
runtime dependencies, not incorporations, and carry no obligation here.

## Packer template for beta macOS images (MIT)

- **What:** `skills/tart-xcode-runner/references/macos-beta.pkr.hcl`, whose
  Setup Assistant boot sequence is derived from Cirrus Labs' vanilla Tahoe
  template.
- **From:** https://github.com/cirruslabs/macos-image-templates
- **Copyright:** Copyright (c) 2018 Cirrus Labs.
- **License:** MIT — the same terms as [`LICENSE`](LICENSE), where the
  upstream copyright notice is preserved alongside ours.
- **Modifications:** rewritten for beta-macOS unattended setup, coordinate
  clicks, and our provisioning inputs.

## Packer plugin patch (MPL-2.0 — see note)

- **What:**
  `skills/tart-xcode-runner/references/packer-plugin-tart-coordinate-click.patch`,
  a patch adding normalized-coordinate clicks and a click timeout to
  `builder/tart/vnc.go`.
- **From:** https://github.com/cirruslabs/packer-plugin-tart, applied to
  commit `c10d61142fdce6ca40c139a6575ce898e867b0f1` by
  `references/prepare-image.zsh`, which clones and builds the plugin locally
  at image-prep time. No upstream source is redistributed by this repository
  — only the patch.
- **MPL-2.0 source availability (§3.4):** the patch is a Modification of
  MPL-2.0-covered files and is itself made available under MPL-2.0. Its
  complete Source Code Form is the patch file itself together with the
  upstream repository at the pinned commit above; the patch is deliberately
  kept header-free so `git apply` consumes it unchanged, and this notice
  serves as its license notice.
- **Copyright:** Copyright (c) 2022 Cirrus Labs, Inc.
- **License:** Mozilla Public License 2.0 —
  https://www.mozilla.org/en-US/MPL/2.0/. MPL-2.0 is a file-level copyleft:
  the files this patch modifies remain MPL-2.0 Covered Software, and the
  patch is a Modification of them. It is **not** covered by this repository's
  MIT [`LICENSE`](LICENSE) and must not be relicensed.
- **Status:** flagged for an ownership decision on how this patch is offered
  and how recipients are pointed at its Source Code Form. Nothing has been
  relabeled pending that decision.

Corrections welcome — an incomplete or wrong notice here is a bug.
[File it](https://github.com/novotnyllc/tart-xcode-runner/issues).
