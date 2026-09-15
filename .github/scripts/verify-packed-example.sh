#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
case "$platform" in
  android | ios | web) ;;
  *)
    echo "Usage: $0 <android|ios|web>"
    exit 1
    ;;
esac

ensure_intune_android_module_includes() {
  local settings_file="android/capacitor.settings.gradle"
  if [ ! -f "$settings_file" ] || grep -q ':intune-mam-sdk' "$settings_file"; then
    return 0
  fi
  bun -e "
const fs = require('node:fs');
const path = require('node:path');
const settingsFile = process.argv[1];
const pluginName = process.argv[2];
const pkgJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const depName =
  Object.keys({ ...pkgJson.dependencies, ...pkgJson.devDependencies }).find((k) =>
    k.includes('capacitor-intune'),
  ) || pluginName;
const pluginRoot = path.dirname(require.resolve(depName + '/package.json'));
const androidDir = path.join(pluginRoot, 'android');
const relAndroid = path
  .relative(path.dirname(settingsFile), androidDir)
  .split(path.sep)
  .join('/');
const relMam = relAndroid + '/intune-mam-sdk';
const relStubs = relAndroid + '/intune-downlevel-stubs';
const block = \`
include ':intune-mam-sdk'
project(':intune-mam-sdk').projectDir = new File('\${relMam}')
include ':intune-downlevel-stubs'
project(':intune-downlevel-stubs').projectDir = new File('\${relStubs}')
\`;
fs.appendFileSync(settingsFile, block);
" "$settings_file" "$plugin_name"
}

ensure_intune_android_maven_repo() {
  local build_file="android/build.gradle"
  local feed="https://pkgs.dev.azure.com/MicrosoftDeviceSDK/DuoSDK-Public/_packaging/Duo-SDK-Feed/maven/v1"
  if [ ! -f "$build_file" ] || grep -q 'DuoSDK-Public' "$build_file"; then
    return 0
  fi
  bun -e "
const fs = require('node:fs');
const file = process.argv[1];
const feed = process.argv[2];
let txt = fs.readFileSync(file, 'utf8');
if (txt.includes('DuoSDK-Public')) process.exit(0);
const block = 'allprojects {\\n    repositories {\\n        google()\\n        mavenCentral()\\n    }\\n}';
const patched = \`allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url '\${feed}'
        }
    }
}\`;
if (!txt.includes(block)) {
  console.error('Could not patch android/build.gradle for Intune Maven feed');
  process.exit(1);
}
fs.writeFileSync(file, txt.replace(block, patched));
" "$build_file" "$feed"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="${RUNNER_TEMP:-$(mktemp -d)}"
pack_dir="$tmp_root/plugin-package"
test_app="$tmp_root/plugin-example-app"

cd "$repo_root"

bun run build

rm -rf "$pack_dir" "$test_app"
mkdir -p "$pack_dir" "$test_app"
bun pm pack --destination "$pack_dir" --quiet

shopt -s nullglob
packed_packages=("$pack_dir"/*.tgz)
shopt -u nullglob
if [ "${#packed_packages[@]}" -ne 1 ]; then
  echo "Expected exactly one package tarball, found ${#packed_packages[@]}"
  exit 1
fi

plugin_name="$(bun -e 'console.log(require("./package.json").name)')"
cp -R example-app/. "$test_app/"
cd "$test_app"
bun remove "$plugin_name"
bun add "${packed_packages[0]}"
bun run build

case "$platform" in
  android)
    if [ ! -d android ]; then
      bunx cap add android
    fi
    bunx cap sync android
    ensure_intune_android_module_includes
    ensure_intune_android_maven_repo
    cd android
    ./gradlew build test
    ;;
  ios)
    if [ ! -d ios ]; then
      bunx cap add ios
    fi
    ios_pbxproj="ios/App/App.xcodeproj/project.pbxproj"
    if [ -f "$ios_pbxproj" ]; then
      sed -i.bak 's/IPHONEOS_DEPLOYMENT_TARGET = 15.0/IPHONEOS_DEPLOYMENT_TARGET = 17.0/g' "$ios_pbxproj"
      rm -f "${ios_pbxproj}.bak"
    fi
    bunx cap sync ios
    rm -rf "$HOME/Library/Caches/org.swift.swiftpm/artifacts"/https___github_com_ionic_team_capacitor_swift_pm_releases_download_*
    xcodebuild \
      -project ios/App/App.xcodeproj \
      -scheme App \
      -destination generic/platform=iOS \
      -clonedSourcePackagesDirPath "$tmp_root/plugin-example-swiftpm" \
      -derivedDataPath "$tmp_root/plugin-example-derived-data" \
      CODE_SIGNING_ALLOWED=NO
    ;;
  web)
    ;;
esac
