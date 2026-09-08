# Fortify v0.6.0 release

The rename is staged until the PR has code-owner approval and all CI and Release
checks pass. Pull-request Release runs build and attest both archive layouts;
they do not publish a GitHub release or modify package repositories.

1. Merge the approved PR to `main`. Rename `EmbrasureAI/embrasure-cli` to
   `EmbrasureAI/fortify` in place, preserving history, releases, and tags. Update
   the local origin URL. Do not recreate a repository at the old name.
2. Confirm the renamed repository still has its rules, Actions permissions,
   secrets, and Homebrew tap token. Tag the merged commit `v0.6.0` and push the tag.
3. Wait for the Release workflow. Verify `SHA256SUMS` and attestations for four
   Unix targets and Windows x64, each under both `fortify-*` and `embrasure-*`
   names. Verify the Windows manifest bundle and `install.ps1` are published.
4. Verify the Homebrew job publishes `Formula/fortify.rb` and the
   `embrasure` → `fortify` entry in `formula_renames.json`, removing the old
   formula. Test a fresh install and migration from the old formula; both
   commands must resolve to the same installed version.
5. Extract the generated Windows manifest bundle. Publish both Scoop manifests
   to `EmbrasureAI/scoop-bucket/bucket/`. They reject simultaneous installation
   of the two package names. Submit the generated Fortify WinGet manifests to
   `microsoft/winget-pkgs`; publish the legacy identity only if it already has an
   accepted listing. Generated manifests are not proof of an accepted listing.
6. Test fresh installs and old-version upgrades against the public release.
   Verify both command names and packaged SQLGlot. Run a disposable workflow
   using `EmbrasureAI/fortify@v1` and confirm it installs v0.6.0.

Existing Action references must change to `EmbrasureAI/fortify@v1`; GitHub does
not redirect them after a rename. Existing Git and release URLs redirect.
See [GitHub repository rename behavior](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository)
and [Homebrew formula migration](https://docs.brew.sh/Rename-A-Formula).

## Compatibility identifiers retained through v0.x

Keep the legacy config filename and environment aliases, OAuth cache directories,
cloud keychain service and ProjectDirs identity, warehouse prefixes and markers,
BigQuery managed labels, reserved SQL aliases, JSON schema IDs, and original
installer test fixtures. Company names, service domains, copyright, and Embrasure
Cloud branding remain Embrasure. No credential migration or warehouse marker
rewrite is required.
