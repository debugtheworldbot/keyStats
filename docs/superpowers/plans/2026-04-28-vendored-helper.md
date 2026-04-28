# Vendored KeyStatsHelper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Implementation note (added during execution):** Task 5's original design — a Run Script build phase inside the KeyStats Xcode target — was abandoned after hitting two Xcode constraints during implementation: (a) declaring `BUILT_PRODUCTS_DIR/KeyStatsHelper.app` as the script's `outputPaths` collides with the helper target's own production of the same file ("Multiple commands produce" error); (b) the project has `ENABLE_USER_SCRIPT_SANDBOXING = YES`, and Xcode's script sandbox denies recursive reads inside `vendor/KeyStatsHelper.app/` even when the bundle root is declared in `inputPaths`. The actual implementation switched to **Approach E**: do the helper swap as a post-archive step in `scripts/build_dmg.sh` and `.github/workflows/release.yml`, via a new `scripts/embed_vendored_helper.sh`. No pbxproj changes. Tasks 5–7 below document the originally-planned Xcode approach for historical reference; the shipped implementation is in commits a02ee2f / af10eeb / ecabb06.

**Goal:** Eliminate helper cdhash drift by vendoring a pre-built, pre-signed `KeyStatsHelper.app` into the repo so CI/local builds produce a `KeyStatsHelper.app` whose cdhash equals the committed vendor copy regardless of toolchain. Result: TCC Accessibility grant survives Sparkle updates that don't touch helper sources.

**Architecture:**
1. Commit `vendor/KeyStatsHelper.app/` (already-signed bundle) and `vendor/KeyStatsHelper.cdhash.txt` into git (binary-tracked via `.gitattributes`).
2. Xcode KeyStats target keeps building the helper target for compile-error sanity, but a Run Script build phase overwrites the freshly-built `BUILT_PRODUCTS_DIR/KeyStatsHelper.app` with the vendored copy before the existing Embed Helper phase fires.
3. `sign_app.sh` stays unchanged — re-signing the vendored helper with the same entitlements is verified deterministic (cdhash preserved).
4. CI and `build_dmg.sh` both call a sanity-check script that verifies the vendored helper's actual cdhash matches `vendor/KeyStatsHelper.cdhash.txt` before any build.
5. Developers update vendor by running `scripts/rebuild_vendored_helper.sh` after touching helper sources; CI rejects the build if vendor is stale.

**Tech Stack:** macOS codesign, xcodebuild, bash, Xcode pbxproj, GitHub Actions.

**Pre-verified facts (mini-spikes already done):**
- ✅ Re-signing a vendored helper with same entitlements preserves cdhash (sign_app.sh is safe).
- ✅ Swapping a vendored helper into a locally-built KeyStats.app and re-signing the outer app (no `--deep`) preserves vendored helper cdhash.
- ✅ Two source entitlement files are already byte-identical (commit `dae6773`).

**Branch:** `ccc` (pushes to `origin/feat/mac-permission`).

---

### Task 1: Add `.gitattributes` for vendored binary tracking

**Files:**
- Create: `.gitattributes`

- [ ] **Step 1: Create `.gitattributes`**

Write file content:

```
vendor/KeyStatsHelper.app/** binary
vendor/KeyStatsHelper.cdhash.txt text eol=lf
```

- [ ] **Step 2: Verify git recognizes the rule**

Run: `git check-attr binary vendor/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper 2>&1 || true`

Expected: prints `vendor/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper: binary: set` (the file doesn't exist yet but the attribute lookup works on path patterns).

- [ ] **Step 3: Commit**

```bash
git add .gitattributes
git commit -m "build(vendor): mark vendored helper bundle as binary in git

Avoid line-ending conversion or text-merge attempts on the Mach-O,
plist, and _CodeSignature contents that would silently change cdhash.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Write `scripts/rebuild_vendored_helper.sh`

**Files:**
- Create: `scripts/rebuild_vendored_helper.sh`

- [ ] **Step 1: Create script**

Write file content:

```bash
#!/bin/bash
# Build, sign, and vendor KeyStatsHelper.app into vendor/.
#
# Run this whenever you change KeyStatsHelper sources or its entitlements.
# CI checks vendor/KeyStatsHelper.cdhash.txt against the committed bundle;
# forgetting to run this after a helper change will fail the build.
#
# Usage: ./scripts/rebuild_vendored_helper.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "🔨 Building KeyStatsHelper (Release, universal)..."
xcodebuild -project KeyStats.xcodeproj \
    -scheme helper \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/dd" \
    CODE_SIGN_IDENTITY="-" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    -destination 'platform=macOS' \
    build > "$BUILD_DIR/xcodebuild.log" 2>&1 \
    || { tail -50 "$BUILD_DIR/xcodebuild.log"; exit 1; }

HELPER_BUILT="$BUILD_DIR/dd/Build/Products/Release/KeyStatsHelper.app"
if [ ! -d "$HELPER_BUILT" ]; then
    echo "❌ Helper build product not found at $HELPER_BUILT"
    exit 1
fi

echo "🔏 Signing helper with KeyStatsHelper.entitlements..."
codesign --force --sign - \
    --entitlements "$PROJECT_DIR/KeyStatsHelper/KeyStatsHelper.entitlements" \
    "$HELPER_BUILT"

CDHASH=$(codesign -d -vvv "$HELPER_BUILT" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}')
if [ -z "$CDHASH" ]; then
    echo "❌ Failed to extract cdhash from signed helper"
    exit 1
fi

echo "📦 Replacing vendor/KeyStatsHelper.app..."
mkdir -p vendor
rm -rf vendor/KeyStatsHelper.app
ditto "$HELPER_BUILT" vendor/KeyStatsHelper.app

echo "$CDHASH" > vendor/KeyStatsHelper.cdhash.txt

echo ""
echo "✅ Vendored helper updated."
echo "   Path:   vendor/KeyStatsHelper.app"
echo "   CDHash: $CDHASH"
echo ""
echo "Next: review with 'git status' and commit both vendor/KeyStatsHelper.app"
echo "and vendor/KeyStatsHelper.cdhash.txt together."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/rebuild_vendored_helper.sh
```

- [ ] **Step 3: Commit (script only — vendor/ generated next task)**

```bash
git add scripts/rebuild_vendored_helper.sh
git commit -m "build(vendor): add rebuild_vendored_helper.sh

Builds KeyStatsHelper standalone (Release, universal), ad-hoc-signs
with KeyStatsHelper.entitlements, then ditto-copies the result into
vendor/KeyStatsHelper.app and writes vendor/KeyStatsHelper.cdhash.txt.
Developers run this whenever they touch helper sources or entitlements.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Generate initial `vendor/KeyStatsHelper.app` and commit

**Files:**
- Create: `vendor/KeyStatsHelper.app/` (entire bundle, several files)
- Create: `vendor/KeyStatsHelper.cdhash.txt`

- [ ] **Step 1: Run the rebuild script**

```bash
./scripts/rebuild_vendored_helper.sh
```

Expected: prints `✅ Vendored helper updated.` with a `CDHash:` line.

- [ ] **Step 2: Verify vendor structure exists**

```bash
ls vendor/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper
cat vendor/KeyStatsHelper.cdhash.txt
codesign -d -vvv vendor/KeyStatsHelper.app 2>&1 | grep CDHash
```

Expected: helper binary exists; cdhash.txt contents match `codesign -d` CDHash output (without prefix).

- [ ] **Step 3: Commit vendor bundle**

```bash
git add vendor/
git commit -m "build(vendor): vendor initial KeyStatsHelper.app bundle

Pre-built, pre-signed helper bundle so CI builds produce a
KeyStatsHelper.app whose cdhash equals this committed copy regardless
of toolchain version. TCC Accessibility grant survives Sparkle
updates that don't touch helper sources.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Write `scripts/check_vendored_helper.sh`

**Files:**
- Create: `scripts/check_vendored_helper.sh`

- [ ] **Step 1: Create script**

Write file content:

```bash
#!/bin/bash
# Verify vendor/KeyStatsHelper.app's actual cdhash matches the value
# recorded in vendor/KeyStatsHelper.cdhash.txt.
#
# Run from CI and from local build_dmg.sh to detect a stale or
# corrupted vendored helper before any further build work.
#
# Exit 0 on match, 1 on mismatch / missing files.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_APP="$PROJECT_DIR/vendor/KeyStatsHelper.app"
EXPECTED_FILE="$PROJECT_DIR/vendor/KeyStatsHelper.cdhash.txt"

if [ ! -d "$VENDOR_APP" ]; then
    echo "❌ Missing vendored helper bundle: $VENDOR_APP"
    echo "   Run: ./scripts/rebuild_vendored_helper.sh"
    exit 1
fi

if [ ! -f "$EXPECTED_FILE" ]; then
    echo "❌ Missing expected cdhash file: $EXPECTED_FILE"
    echo "   Run: ./scripts/rebuild_vendored_helper.sh"
    exit 1
fi

EXPECTED=$(tr -d '[:space:]' < "$EXPECTED_FILE")
ACTUAL=$(codesign -d -vvv "$VENDOR_APP" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}' | tr -d '[:space:]')

if [ -z "$ACTUAL" ]; then
    echo "❌ Failed to extract cdhash from $VENDOR_APP (codesign -d failed?)"
    exit 1
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "❌ Vendored helper cdhash mismatch."
    echo "   Expected (vendor/KeyStatsHelper.cdhash.txt): $EXPECTED"
    echo "   Actual   (vendor/KeyStatsHelper.app):        $ACTUAL"
    echo ""
    echo "   The vendored bundle was modified without updating cdhash.txt,"
    echo "   or the helper sources changed without re-vendoring. Run:"
    echo "     ./scripts/rebuild_vendored_helper.sh"
    echo "   then commit both vendor/KeyStatsHelper.app and vendor/KeyStatsHelper.cdhash.txt."
    exit 1
fi

echo "✅ Vendored helper cdhash OK: $ACTUAL"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/check_vendored_helper.sh
```

- [ ] **Step 3: Run check to verify it passes against the committed vendor**

```bash
./scripts/check_vendored_helper.sh
```

Expected: `✅ Vendored helper cdhash OK: <hash>` and exit 0.

- [ ] **Step 4: Run negative test**

Temporarily modify cdhash.txt to verify the check fails:

```bash
cp vendor/KeyStatsHelper.cdhash.txt vendor/KeyStatsHelper.cdhash.txt.bak
echo "0000000000000000000000000000000000000000" > vendor/KeyStatsHelper.cdhash.txt
./scripts/check_vendored_helper.sh; RC=$?
mv vendor/KeyStatsHelper.cdhash.txt.bak vendor/KeyStatsHelper.cdhash.txt
[ $RC -eq 1 ] && echo "✅ negative test passed" || (echo "❌ check did not fail as expected"; exit 1)
```

Expected: prints mismatch error then `✅ negative test passed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/check_vendored_helper.sh
git commit -m "build(vendor): add check_vendored_helper.sh

Sanity check that vendor/KeyStatsHelper.app's actual cdhash matches
vendor/KeyStatsHelper.cdhash.txt. CI runs this to catch a stale vendor
(developer changed helper sources without re-running
rebuild_vendored_helper.sh).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Modify Xcode KeyStats target to embed the vendored helper

**Files:**
- Modify: `KeyStats.xcodeproj/project.pbxproj` (insert PBXShellScriptBuildPhase before Embed Helper)

**Background:** `KeyStats` target currently has a `PBXCopyFilesBuildPhase` named "Embed Helper" (id `9479D3FB2F9B67140083A75E`) that copies `BUILT_PRODUCTS_DIR/KeyStatsHelper.app` (helper target's output) into `KeyStats.app/Contents/Resources/`. We keep that phase exactly as-is, but insert a Run Script phase **before** it that overwrites `BUILT_PRODUCTS_DIR/KeyStatsHelper.app` with the vendored bundle. Xcode keeps building the helper target (so compile errors still surface), but the embedded artifact ends up being the vendored copy.

- [ ] **Step 1: Locate the Embed Helper phase id and KeyStats target's buildPhases array**

Run:

```bash
grep -n "9479D3FB2F9B67140083A75E\|/* Embed Helper \*/\|A4000003 /\* Resources \*/" KeyStats.xcodeproj/project.pbxproj
```

Expected: shows the `Embed Helper` PBXCopyFilesBuildPhase (id `9479D3FB2F9B67140083A75E`) and KeyStats target's `buildPhases` block listing it after `A4000003 /* Resources */`.

- [ ] **Step 2: Generate stable ids for the new shell script phase**

Use deterministic ids in the existing project's id space:

- New PBXShellScriptBuildPhase id: `9479D3FD2F9B67500083A75E` (chosen to fit the existing 9479D3xx range and not collide)

Verify it doesn't collide:

```bash
grep "9479D3FD2F9B67500083A75E" KeyStats.xcodeproj/project.pbxproj
```

Expected: no matches.

- [ ] **Step 3: Add the PBXShellScriptBuildPhase definition**

Find the `/* Begin PBXCopyFilesBuildPhase section */` block (around line 57). Immediately after `/* End PBXCopyFilesBuildPhase section */` (around line 69), the file has other PBX sections — find a clean insertion point (or look for an existing `PBXShellScriptBuildPhase` section if any exists).

Run:

```bash
grep -n "PBXShellScriptBuildPhase" KeyStats.xcodeproj/project.pbxproj
```

If the section exists, insert the new phase inside it. If it doesn't, create the section right after `/* End PBXCopyFilesBuildPhase section */`:

Insert this block:

```
/* Begin PBXShellScriptBuildPhase section */
		9479D3FD2F9B67500083A75E /* Replace built helper with vendored */ = {
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
				"$(SRCROOT)/vendor/KeyStatsHelper.app",
			);
			name = "Replace built helper with vendored";
			outputFileListPaths = (
			);
			outputPaths = (
				"$(BUILT_PRODUCTS_DIR)/KeyStatsHelper.app",
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/bash;
			shellScript = "set -e\n\"$SRCROOT/scripts/check_vendored_helper.sh\"\nrm -rf \"$BUILT_PRODUCTS_DIR/KeyStatsHelper.app\"\nditto \"$SRCROOT/vendor/KeyStatsHelper.app\" \"$BUILT_PRODUCTS_DIR/KeyStatsHelper.app\"\n";
		};
/* End PBXShellScriptBuildPhase section */
```

- [ ] **Step 4: Insert the new phase id into KeyStats target's buildPhases list**

Find the KeyStats target's `buildPhases` array (after line 237 in original — search for the block containing `A4000003 /* Resources */` followed by `9479D3FB2F9B67140083A75E /* Embed Helper */`).

Original block (verified at lines 234-239 in current pbxproj):

```
			buildPhases = (
				A4000002 /* Sources */,
				A4000001 /* Frameworks */,
				A4000003 /* Resources */,
				9479D3FB2F9B67140083A75E /* Embed Helper */,
			);
```

Replace with:

```
			buildPhases = (
				A4000002 /* Sources */,
				A4000001 /* Frameworks */,
				A4000003 /* Resources */,
				9479D3FD2F9B67500083A75E /* Replace built helper with vendored */,
				9479D3FB2F9B67140083A75E /* Embed Helper */,
			);
```

(the new phase id sits between Resources and Embed Helper)

- [ ] **Step 5: Open the project in Xcode and verify the project loads cleanly**

```bash
open KeyStats.xcodeproj
```

In Xcode: select KeyStats target → Build Phases. Expected: see "Replace built helper with vendored" listed above "Embed Helper" with the shell script body visible. If Xcode reports "the project file is corrupted," revert the pbxproj edit and try again with smaller hunks.

Close Xcode after verifying.

- [ ] **Step 6: Build with xcodebuild to verify the new phase runs**

```bash
xcodebuild -project KeyStats.xcodeproj -scheme KeyStats -configuration Release \
  -derivedDataPath /tmp/keystats-vendor-test/dd \
  CODE_SIGN_IDENTITY="-" build 2>&1 | grep -E "Replace built helper|✅ Vendored helper cdhash"
```

Expected: shows the script ran and printed `✅ Vendored helper cdhash OK: ...`.

- [ ] **Step 7: Verify the embedded helper in the built app matches vendor cdhash**

```bash
EMBEDDED="/tmp/keystats-vendor-test/dd/Build/Products/Release/KeyStats.app/Contents/Resources/KeyStatsHelper.app"
ACTUAL=$(codesign -d -vvv "$EMBEDDED" 2>&1 | awk -F= '/^CDHash=/{print $2}')
EXPECTED=$(cat vendor/KeyStatsHelper.cdhash.txt)
echo "embedded: $ACTUAL"
echo "vendor:   $EXPECTED"
[ "$ACTUAL" = "$EXPECTED" ] && echo "✅ embedded matches vendor" || echo "❌ mismatch"
```

Expected: `✅ embedded matches vendor`.

- [ ] **Step 8: Cleanup test build dir**

```bash
rm -rf /tmp/keystats-vendor-test
```

- [ ] **Step 9: Commit**

```bash
git add KeyStats.xcodeproj/project.pbxproj
git commit -m "build(xcode): embed vendored KeyStatsHelper instead of fresh build

KeyStats target keeps building the helper target so compile errors
still surface, but a new Run Script build phase (placed before Embed
Helper) overwrites BUILT_PRODUCTS_DIR/KeyStatsHelper.app with
vendor/KeyStatsHelper.app. The existing Copy Files phase then embeds
the vendored bundle into KeyStats.app/Contents/Resources/. Together
with sign_app.sh's inner-first signing (no --deep), the embedded
helper's cdhash equals vendor/KeyStatsHelper.cdhash.txt regardless of
toolchain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Make `build_dmg.sh` call `check_vendored_helper.sh`

**Files:**
- Modify: `scripts/build_dmg.sh` (insert one line after the cleanup block)

- [ ] **Step 1: Read the current build_dmg.sh to find the right insertion point**

Run:

```bash
grep -n "rm -rf\|xcodebuild" scripts/build_dmg.sh
```

Expected: shows the `rm -rf "$BUILD_DIR"` line (around line 25) and the `xcodebuild` archive call (around line 30).

- [ ] **Step 2: Insert check call between the cleanup and the xcodebuild step**

Open `scripts/build_dmg.sh` and find the block:

```bash
# 清理旧的构建
echo "🧹 清理旧的构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR" "$OUTPUT_DIR"

# 构建 Release 版本
```

Replace with:

```bash
# 清理旧的构建
echo "🧹 清理旧的构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR" "$OUTPUT_DIR"

# 校验 vendor 里的 helper 跟 cdhash.txt 一致
echo "🔍 校验 vendored helper..."
"$SCRIPT_DIR/check_vendored_helper.sh"

# 构建 Release 版本
```

- [ ] **Step 3: Verify by running build_dmg.sh end to end**

```bash
./scripts/build_dmg.sh
```

Expected: prints `✅ Vendored helper cdhash OK: ...` early in the output, completes successfully, prints `✅ 打包完成！`.

- [ ] **Step 4: Verify resulting DMG embeds vendored helper**

```bash
TMP=$(mktemp -d); cd "$TMP"
MOUNT=$(hdiutil attach -nobrowse -readonly /Users/tian/Developer/keyStats/KeyStats.dmg | tail -1 | awk '{print $3}')
ACTUAL=$(codesign -d -vvv "$MOUNT/KeyStats.app/Contents/Resources/KeyStatsHelper.app" 2>&1 | awk -F= '/^CDHash=/{print $2}')
EXPECTED=$(cat /Users/tian/Developer/keyStats/vendor/KeyStatsHelper.cdhash.txt)
hdiutil detach "$MOUNT" -quiet
cd / ; rm -rf "$TMP"
echo "embedded: $ACTUAL"
echo "vendor:   $EXPECTED"
[ "$ACTUAL" = "$EXPECTED" ] && echo "✅ DMG embeds vendored helper" || echo "❌ mismatch"
```

Expected: `✅ DMG embeds vendored helper`.

- [ ] **Step 5: Commit**

```bash
git add scripts/build_dmg.sh
git commit -m "build(dmg): verify vendored helper before archive

Catch a stale or corrupted vendor/KeyStatsHelper.app early instead of
discovering the cdhash drift only after the DMG ships.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Make `release.yml` (CI) call `check_vendored_helper.sh`

**Files:**
- Modify: `.github/workflows/release.yml` (insert a step before the Sparkle build step)

- [ ] **Step 1: Locate the right insertion point**

Run:

```bash
grep -n "Build Sparkle update archive\|Build DMG" .github/workflows/release.yml
```

Expected: shows the `Build DMG` step (around line 37) and `Build Sparkle update archive` step (around line 69).

- [ ] **Step 2: Insert a check step right after `Update app version`**

Open `.github/workflows/release.yml`. Find:

```yaml
      - name: Update app version
        run: |
          VERSION=${{ steps.version.outputs.VERSION }}
          sed -i '' "s/MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION;/" KeyStats.xcodeproj/project.pbxproj
          echo "Updated MARKETING_VERSION to $VERSION"

      - name: Build DMG
```

Insert a new step between them:

```yaml
      - name: Update app version
        run: |
          VERSION=${{ steps.version.outputs.VERSION }}
          sed -i '' "s/MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION;/" KeyStats.xcodeproj/project.pbxproj
          echo "Updated MARKETING_VERSION to $VERSION"

      - name: Verify vendored helper
        run: ./scripts/check_vendored_helper.sh

      - name: Build DMG
```

- [ ] **Step 3: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "✅ YAML valid"
```

Expected: `✅ YAML valid`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): verify vendored helper before macOS build

Fails the workflow early with a clear message if vendor/ is stale,
rather than letting a drifted helper ship and silently invalidate
TCC grants on every user's machine.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Local end-to-end verification

**Files:** none (verification only)

- [ ] **Step 1: Clean local build artifacts**

```bash
rm -f KeyStats.dmg
rm -rf build
```

- [ ] **Step 2: Run build_dmg.sh fresh**

```bash
./scripts/build_dmg.sh
```

Expected: ends with `✅ 打包完成！` and outputs `KeyStats.dmg` at the project root.

- [ ] **Step 3: Verify all three points where helper appears all show the same cdhash**

```bash
TMP=$(mktemp -d)
MOUNT=$(hdiutil attach -nobrowse -readonly KeyStats.dmg | tail -1 | awk '{print $3}')

VENDOR_HASH=$(cat vendor/KeyStatsHelper.cdhash.txt)
VENDOR_DIRECT=$(codesign -d -vvv vendor/KeyStatsHelper.app 2>&1 | awk -F= '/^CDHash=/{print $2}')
DMG_EMBEDDED=$(codesign -d -vvv "$MOUNT/KeyStats.app/Contents/Resources/KeyStatsHelper.app" 2>&1 | awk -F= '/^CDHash=/{print $2}')

hdiutil detach "$MOUNT" -quiet
rm -rf "$TMP"

echo "vendor/KeyStatsHelper.cdhash.txt:    $VENDOR_HASH"
echo "vendor/KeyStatsHelper.app (actual):  $VENDOR_DIRECT"
echo "DMG embedded helper:                 $DMG_EMBEDDED"

if [ "$VENDOR_HASH" = "$VENDOR_DIRECT" ] && [ "$VENDOR_HASH" = "$DMG_EMBEDDED" ]; then
    echo "✅ All three cdhashes match — vendored pipeline works end-to-end"
else
    echo "❌ Mismatch — investigate which step diverged"
    exit 1
fi
```

Expected: `✅ All three cdhashes match`.

- [ ] **Step 4: Run a second time to confirm reproducibility**

```bash
rm -f KeyStats.dmg
rm -rf build
./scripts/build_dmg.sh

MOUNT=$(hdiutil attach -nobrowse -readonly KeyStats.dmg | tail -1 | awk '{print $3}')
RUN2=$(codesign -d -vvv "$MOUNT/KeyStats.app/Contents/Resources/KeyStatsHelper.app" 2>&1 | awk -F= '/^CDHash=/{print $2}')
hdiutil detach "$MOUNT" -quiet

VENDOR_HASH=$(cat vendor/KeyStatsHelper.cdhash.txt)
[ "$RUN2" = "$VENDOR_HASH" ] && echo "✅ reproducible across runs" || echo "❌ run 2 diverged"
```

Expected: `✅ reproducible across runs`.

- [ ] **Step 5: No commit needed (verification only). Move to Task 9.**

---

### Task 9: CI end-to-end verification (publish v1.44-beta.5)

**Files:** none (push tag only)

- [ ] **Step 1: Push current branch and tag v1.44-beta.5**

```bash
git push origin ccc:feat/mac-permission
NEW=$(git rev-parse HEAD)
git tag v1.44-beta.5 "$NEW"
git push origin v1.44-beta.5
```

Expected: branch + tag pushed, GitHub Actions release workflow triggered.

- [ ] **Step 2: Wait for workflow to complete**

```bash
gh run watch $(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: exit code 0; logs show `Verify vendored helper` step succeeded.

- [ ] **Step 3: Download CI build and verify cdhash equals vendor cdhash**

```bash
TMP=$(mktemp -d); cd "$TMP"
curl -fsSL -o b5.zip https://github.com/debugtheworldbot/keyStats/releases/download/v1.44-beta.5/KeyStats.zip
unzip -q b5.zip
CI_HASH=$(codesign -d -vvv KeyStats.app/Contents/Resources/KeyStatsHelper.app 2>&1 | awk -F= '/^CDHash=/{print $2}')
VENDOR_HASH=$(cat /Users/tian/Developer/keyStats/vendor/KeyStatsHelper.cdhash.txt)
echo "CI helper:   $CI_HASH"
echo "Vendor:      $VENDOR_HASH"
cd / ; rm -rf "$TMP"
[ "$CI_HASH" = "$VENDOR_HASH" ] && echo "✅ CI build emits vendored helper exactly — TCC stable across releases" || echo "❌ CI helper diverged from vendor"
```

Expected: `✅ CI build emits vendored helper exactly`.

- [ ] **Step 4: No commit needed. Move to Task 10.**

---

### Task 10: Document developer protocol in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (append a new section near the existing "Critical Rules" section)

- [ ] **Step 1: Find the right insertion point**

Run:

```bash
grep -n "## Critical Rules\|## Dependencies (SPM)" CLAUDE.md
```

Expected: shows the existing section anchors. We'll insert a new section between "Code Conventions" and "Dependencies (SPM)".

- [ ] **Step 2: Add a "Vendored Helper" subsection under "Critical Rules"**

Open `CLAUDE.md`. Find:

```markdown
### Code Conventions
- Localize user-facing strings with `NSLocalizedString()` (English + Simplified Chinese)
- Use `[weak self]` in closures to prevent retain cycles
- Maintain backward compatibility with existing UserDefaults keys when changing data models

## Dependencies (SPM)
```

Insert between them:

```markdown
### Code Conventions
- Localize user-facing strings with `NSLocalizedString()` (English + Simplified Chinese)
- Use `[weak self]` in closures to prevent retain cycles
- Maintain backward compatibility with existing UserDefaults keys when changing data models

### Vendored Helper

`KeyStatsHelper.app` is **vendored** at `vendor/KeyStatsHelper.app/` (committed binary, see `.gitattributes`). CI and `build_dmg.sh` embed this exact bundle into `KeyStats.app/Contents/Resources/` so the helper's cdhash stays constant across releases — TCC Accessibility grant survives Sparkle updates.

**When you change anything under `KeyStatsHelper/` (sources, Info.plist, entitlements, build settings):**

1. Run `./scripts/rebuild_vendored_helper.sh` (rebuilds + signs + writes new vendor bundle and `cdhash.txt`)
2. Commit `vendor/` and the helper source change in the same commit
3. CI's `Verify vendored helper` step will fail if you forget — `cdhash.txt` will mismatch the bundle's actual cdhash.

The helper target itself still builds during `xcodebuild` (so compile errors surface in Xcode), but its build product is overwritten by the vendored bundle in a Run Script phase before being embedded.

## Dependencies (SPM)
```

- [ ] **Step 3: Verify the markdown still parses cleanly**

```bash
grep -c "^## " CLAUDE.md
grep -c "^### " CLAUDE.md
```

Expected: section counts increase by 0 (`##`) and 1 (`###`) compared to before.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): document vendored helper developer protocol

When KeyStatsHelper/ sources change, run rebuild_vendored_helper.sh
and commit vendor/ together with the source change. CI's verify step
catches the mistake otherwise.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Push final commit**

```bash
git push origin ccc:feat/mac-permission
```

---

## Done

After all tasks:
- `vendor/KeyStatsHelper.app/` and `vendor/KeyStatsHelper.cdhash.txt` exist and are committed
- `scripts/rebuild_vendored_helper.sh` and `scripts/check_vendored_helper.sh` exist and are executable
- `KeyStats.xcodeproj/project.pbxproj` has the new Run Script phase before Embed Helper
- `scripts/build_dmg.sh` and `.github/workflows/release.yml` both call `check_vendored_helper.sh` before any build
- `CLAUDE.md` documents the protocol
- v1.44-beta.5 published with `helper cdhash == vendor cdhash`

**Long-term invariants:**
- Helper cdhash only changes when a developer intentionally runs `rebuild_vendored_helper.sh` (i.e. helper sources actually changed)
- Toolchain upgrades on `macos-26` runner no longer affect helper cdhash
- TCC Accessibility grant survives any Sparkle update that doesn't re-vendor the helper
