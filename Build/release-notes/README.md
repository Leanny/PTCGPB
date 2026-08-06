# Release notes

To provide custom notes for a release, add a Markdown file whose name exactly matches the release tag:

```text
Build/release-notes/v0.16.0.md
Build/release-notes/v0.17.0-beta.1.md
```

Commit the notes file before pushing the matching tag. The release workflow uses the file as the GitHub Release description.

If the matching file does not exist, GitHub automatically generates release notes from the commits and pull requests since the previous release.

A typical notes file looks like this:

```markdown
## Highlights

- Added stable and beta update channels.
- Added verified release bundles and automatic checksum validation.

## Fixes

- Fixed an updater configuration issue.

## Upgrade notes

- Existing settings and account data are preserved automatically.
```
