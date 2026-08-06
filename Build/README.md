# PTCGPB release pipeline

Releases are created by `.github/workflows/release.yml` when a semantic-version tag is pushed.

## Publish a stable release

1. Set `localVersion` in `PTCGPB.ahk` to the new tag, for example `v0.16.0`.
2. Commit and push that change.
3. Optionally add custom release notes at `Build/release-notes/v0.16.0.md` and include them in the commit.
4. Tag that commit and push the tag:

   ```powershell
   git tag v0.16.0
   git push origin v0.16.0
   ```

## Publish a prerelease

Use a SemVer prerelease tag. Tags containing a suffix after the patch number are automatically marked as GitHub prereleases:

```powershell
git tag v0.17.0-beta.1
git push origin v0.17.0-beta.1
```

The workflow rebuilds the Rust helpers and publishes these assets:

- `PTCGPB-<tag>.zip`
- `PTCGPB-<tag>.zip.sha256`
- `update-manifest.json`

The ZIP also contains `.ptcgpb-managed-files.txt`. PTCGPB uses that list to replace and remove application-owned files without deleting settings, accounts, logs, screenshots, or event data.

Both Rust helpers use one shared Cargo target directory. Cargo registry data, Git dependencies, and compiled target artifacts are cached across workflow runs using a key derived from the runner, Rust toolchain, and both helpers' Cargo manifests/lockfiles. The first cold build still compiles all required crates; identical dependencies are reused by the second helper and subsequent runs.

If `Build/release-notes/<tag>.md` exists, its Markdown becomes the GitHub Release description. Otherwise, GitHub-generated release notes are used.

## Test in GitHub Actions without publishing

After the workflow exists on the default branch, open **Actions → Build release bundle → Run workflow**. Enter a version that exactly matches `localVersion`. The manual run builds both helpers, packages and verifies the bundle, and uploads the `dist` directory as a seven-day workflow artifact. It does not create a GitHub Release.

## Test packaging locally

Run PowerShell with an execution-policy override if local policy blocks scripts:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build\Package-Release.ps1 -Version v0.16.0 -OutputDirectory .\dist
```

`Build/package-include.txt` is the release allowlist. Add new application files there when introducing a new top-level file or directory. Allowlisted files must be Git-tracked, except for the two helper executables built by CI. User-generated files must not be added.
