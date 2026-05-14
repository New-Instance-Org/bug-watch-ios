# Releasing — iOS

Step-by-step for publishing a new version of LiveAndAiChat to **CocoaPods**
and making it available via **Swift Package Manager**.

## One-time setup

```bash
# Install the CocoaPods CLI if needed.
sudo gem install cocoapods

# Register your CocoaPods Trunk account (replace with your email/name).
pod trunk register you@newinstance.cloud "Your Name" --description="laptop"
# A confirmation link will be emailed — click it before continuing.

# Confirm:
pod trunk me
```

## Per-release checklist

1. **Bump the version** in two places (must match):

   ```ruby
   # LiveAndAiChat.podspec
   s.version = "0.2.0"
   ```

   ```swift
   // (No version constant in Package.swift — SPM uses git tags.)
   ```

2. **Update the changelog** in this file or `CHANGELOG.md` with the new
   version's notable changes.

3. **Verify the build is clean**:

   ```bash
   swift build
   swift test
   xcodebuild -scheme LiveAndAiChat \
              -destination 'generic/platform=iOS Simulator' build
   ```

4. **Lint the podspec** (catches metadata issues, missing sources, etc.):

   ```bash
   pod lib lint LiveAndAiChat.podspec --allow-warnings
   ```

   Warnings about the long description / vendored Apache-2.0 source are
   expected; errors are not.

5. **Commit and tag**. The tag name must match `s.version` exactly:

   ```bash
   git add -A
   git commit -m "Release 0.2.0"
   git tag 0.2.0
   git push origin main --tags
   ```

   Once the tag is on GitLab, the package is **immediately available to
   Swift Package Manager** — consumers just point their dependency at
   `0.2.0` (or `from: "0.2.0"`).

6. **Publish to CocoaPods Trunk**:

   ```bash
   pod trunk push LiveAndAiChat.podspec --allow-warnings
   ```

   CocoaPods will:
   - Re-fetch the tag from the public GitHub mirror declared in the podspec
     (`https://github.com/talktothelaw/new-instance-livechat.git`).
     The GitLab `mirror_to_talktothelaw` CI job pushes every commit + tag
     from `origin` (GitLab) to that GitHub URL, so the tagged commit is
     available there shortly after `git push origin --tags`.
   - Run `pod spec lint` server-side
   - Publish to the master spec repo

   Indexing on cocoapods.org takes ~15-30 minutes.

## Verification

```bash
# SPM — a clean test consumer
mkdir /tmp/spm-check && cd /tmp/spm-check
swift package init --type executable
# Edit Package.swift to add LiveAndAiChat as a dependency:
#   .package(url: "https://github.com/talktothelaw/new-instance-livechat.git", from: "0.2.0")
swift package resolve

# CocoaPods — a clean test consumer (after trunk push completes)
mkdir /tmp/cp-check && cd /tmp/cp-check
pod init  # then add `pod 'LiveAndAiChat', '~> 0.2.0'` to the Podfile
pod install --repo-update
```

## Troubleshooting

- **`pod trunk push` rejects with "missing license"** — the podspec must use
  `license = { :type => "MIT", :file => "LICENSE" }` AND the LICENSE file must
  be present in the tagged commit. Check both.

- **`pod lib lint` fails on `LACEventSource` access modifiers** — the vendored
  EventSource code is intentionally internal-scoped. If lint complains about
  re-exported symbols, increase severity to `--allow-warnings`.

- **SPM resolve hangs forever** — usually a private repo with no SSH key set
  up on the resolving machine. The public GitLab URL is `https://` so this
  shouldn't happen, but check `~/.ssh/config` if anyone uses a custom remote.
