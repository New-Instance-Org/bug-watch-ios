# Releasing — iOS

Step-by-step for publishing a new version of BugWatch to **CocoaPods** and
making it available via **Swift Package Manager**.

> The BugWatch GitLab project, GitHub mirror, and publishing credentials are
> wired up in a later milestone. Until then, treat the URLs below as the
> intended targets.

## One-time setup

```bash
sudo gem install cocoapods
pod trunk register you@newinstance.cloud "Your Name" --description="laptop"
pod trunk me
```

## Per-release checklist

1. **Bump the version** in `BugWatch.podspec` (`s.version`). SPM uses git tags,
   so there is no version constant in `Package.swift`.

2. **Update `CHANGELOG.md`** with the new version's notable changes.

3. **Verify the build is clean**:

   ```bash
   swift build
   swift test
   xcodebuild -scheme BugWatch -destination 'generic/platform=iOS Simulator' build
   ```

4. **Lint the podspec**:

   ```bash
   pod lib lint BugWatch.podspec --allow-warnings
   ```

5. **Commit and tag** (tag must match `s.version` exactly):

   ```bash
   git add -A
   git commit -m "Release 0.2.0"
   git tag 0.2.0
   git push origin main --tags
   ```

   Once the tag is pushed, the package is immediately available to Swift
   Package Manager.

6. **Publish to CocoaPods Trunk**:

   ```bash
   pod trunk push BugWatch.podspec --allow-warnings
   ```

   Indexing on cocoapods.org takes ~15–30 minutes.

## Verification

```bash
# SPM — clean consumer
mkdir /tmp/spm-check && cd /tmp/spm-check
swift package init --type executable
# add: .package(url: "https://github.com/talktothelaw/bug-watch-ios.git", from: "0.2.0")
swift package resolve

# CocoaPods — clean consumer
mkdir /tmp/cp-check && cd /tmp/cp-check
pod init  # add: pod 'BugWatch', '~> 0.2.0'
pod install --repo-update
```

## Troubleshooting

- **`pod trunk push` rejects with "missing license"** — the podspec must use
  `license = { :type => "MIT", :file => "LICENSE" }` AND the LICENSE file must
  be present in the tagged commit.

- **`swift build` fails with `missing required module 'SwiftShims'`** — a stale
  `.build/` copied from another directory. Run `rm -rf .build` and rebuild.
