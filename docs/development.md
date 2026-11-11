# Development

## Build and test

```bash
swift build
```

```bash
swift test
```

`swift test` runs the unit and integration tests against an in-process fake server: a scripted SMTP server on
`127.0.0.1` with a test CA. The tests need no network access.

The test PKI lives in `Tests/SwiftySMTPClientTests/Fixtures`. To regenerate it:

```bash
scripts/generate-test-certs.sh
```

## CI

Everything runs in [`ci.yml`](../.github/workflows/ci.yml):

- **Every push to any branch, and pull requests from forks:** `swift test` on Linux with Swift 6.2 (the oldest
  supported toolchain) and 6.4, and on macOS with Xcode 26, plus a build for iOS. Pull requests from this repository
  are already tested by the push of their branch.
- **Every push to `main`:** once all tests pass, a new version is released right away. The workflow creates the git
  tag and the GitHub release. SwiftPM reads versions straight from the tags, so there is no registry to upload to.

## Releases

The new version follows from the commit messages since the last release
([Conventional Commits](https://www.conventionalcommits.org), [`scripts/release-version.sh`](../scripts/release-version.sh)):

| Commits since the last release                                        | while `0.x`       | from `1.0.0` on   |
|-----------------------------------------------------------------------|-------------------|-------------------|
| a breaking change: `feat!: …`, `fix(api)!: …` or a `BREAKING CHANGE:` footer | `0.1.3` → `0.2.0` | `1.4.2` → `2.0.0` |
| at least one `feat: …`                                                | `0.1.3` → `0.1.4` | `1.4.2` → `1.5.0` |
| anything else (`fix:`, `docs:`, `ci:`, `refactor:`, …)                | `0.1.3` → `0.1.4` | `1.4.2` → `1.4.3` |

The first push releases `0.1.0`. All commits of one push end up in one release. The release notes list them,
followed by GitHub's generated notes (merged pull requests and a compare link).

- **Push without a release:** put `[skip ci]` in the commit message (of the last commit, if you push several). This
  skips the tests as well.
- **Failing tests:** nothing is released. The next green push releases those commits too.
- **`1.0.0`** is never reached automatically. When the API is stable, create it once by hand; later pushes continue
  from there:

  ```bash
  gh release create 1.0.0 --target main --generate-notes
  ```

- **Never move or delete a published tag.** SwiftPM pins the commit in `Package.resolved`, so a moved tag breaks
  resolution for everyone who already uses it. Push a fix instead; it becomes the next patch version.
