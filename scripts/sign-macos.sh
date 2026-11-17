#!/usr/bin/env bash
set -euo pipefail

# Hosted macOS runner only. The output is committed atomically after Apple's
# acceptance, staple validation, and Gatekeeper assessment all succeed.
[[ $# == 3 ]] || { echo 'Usage: sign-macos.sh BINARY VERSION OUTPUT_DIRECTORY' >&2; exit 2; }
binary=$1
version=$2
output_dir=$3
[[ $(uname -s) == Darwin ]] || { echo 'macOS is required' >&2; exit 1; }
[[ -f $binary && -x $binary ]] || { echo 'An executable build is required' >&2; exit 1; }
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+-internal\.[0-9]+$ ]] || { echo 'An internal release version is required' >&2; exit 1; }
for name in APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID RUNNER_TEMP; do
  [[ -n ${!name:-} ]] || { echo "Missing release secret or runner variable: $name" >&2; exit 1; }
done

work=$(mktemp -d "$RUNNER_TEMP/cursor-byok-signing.XXXXXX")
keychain="$work/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
chmod 0700 "$work"
export SIGNING_CERTIFICATE_PATH="$work/application.p12"
python3 - <<'PY'
import base64, os, pathlib
path = pathlib.Path(os.environ['SIGNING_CERTIFICATE_PATH'])
path.write_bytes(base64.b64decode(os.environ['APPLE_CERTIFICATE_BASE64'], validate=True))
path.chmod(0o600)
PY
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$SIGNING_CERTIFICATE_PATH" -k "$keychain" \
  -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$keychain_password" "$keychain" >/dev/null
identity=$(security find-identity -v -p codesigning "$keychain" |
  awk -v team="$APPLE_TEAM_ID" 'index($0,"Developer ID Application:") && index($0,"(" team ")") {print $2; exit}')
[[ $identity =~ ^[0-9A-Fa-f]{40}$ ]] || { echo 'Matching Developer ID Application identity is required' >&2; exit 1; }

arch=$(lipo -archs "$binary")
case $arch in arm64) target=arm64 ;; x86_64) target=amd64 ;; *) echo 'Expected one macOS architecture' >&2; exit 1 ;; esac
stem="cursor-cli-byok-darwin-$target"
mkdir "$work/payload"
cp "$binary" "$work/payload/cursor-cli-byok"
cp LICENSE "$work/payload/LICENSE"
codesign --force --options runtime --timestamp --keychain "$keychain" \
  --identifier com.robinmordasiewicz.cursor-cli-byok --sign "$identity" "$work/payload/cursor-cli-byok"
codesign --verify --strict "$work/payload/cursor-cli-byok"
details=$(codesign -dv --verbose=4 "$work/payload/cursor-cli-byok" 2>&1)
grep -Fq "Authority=Developer ID Application:" <<< "$details"
grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" <<< "$details"
if grep -Fq 'Signature=adhoc' <<< "$details"; then
  echo 'Ad-hoc signing is not accepted for release' >&2
  exit 1
fi

hdiutil create -quiet -fs HFS+ -format UDZO -volname 'Cursor CLI BYOK' \
  -srcfolder "$work/payload" "$work/$stem.dmg"
codesign --timestamp --keychain "$keychain" --sign "$identity" "$work/$stem.dmg"
codesign --verify --strict "$work/$stem.dmg"
xcrun notarytool submit "$work/$stem.dmg" --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait \
  --timeout 20m --output-format json > "$work/notary.json"
python3 - "$work/notary.json" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get('status') != 'Accepted' or not result.get('id'):
    raise SystemExit('Apple did not accept the notarization submission')
PY
xcrun stapler staple "$work/$stem.dmg"
xcrun stapler validate "$work/$stem.dmg"
assessment=$(spctl --assess --type open --context context:primary-signature --verbose=4 "$work/$stem.dmg" 2>&1)
grep -Fq 'source=Notarized Developer ID' <<< "$assessment"

export SIGNING_WORK_DIR="$work" SIGNING_STEM="$stem" SIGNING_VERSION="$version" SIGNING_ARCH="$arch"
python3 - <<'PY'
import hashlib, json, os, pathlib
root = pathlib.Path(os.environ['SIGNING_WORK_DIR'])
stem = os.environ['SIGNING_STEM']
dmg = root / (stem + '.dmg')
binary = root / 'payload/cursor-cli-byok'
notary = json.loads((root / 'notary.json').read_text())
receipt = {'version': os.environ['SIGNING_VERSION'], 'source_commit': os.environ.get('SOURCE_COMMIT', ''),
           'architecture': os.environ['SIGNING_ARCH'], 'team_id': os.environ['APPLE_TEAM_ID'],
           'notarization_id': notary['id'], 'notarization_status': notary['status'],
           'staple_validated': True, 'gatekeeper_accepted': True,
           'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
           'dmg_sha256': hashlib.sha256(dmg.read_bytes()).hexdigest()}
(root / (stem + '.receipt.json')).write_text(json.dumps(receipt, indent=2) + '\n')
(root / (stem + '.dmg.sha256')).write_text(receipt['dmg_sha256'] + '  ' + dmg.name + '\n')
PY
mkdir -p "$output_dir"
cp "$work/$stem.dmg" "$work/$stem.dmg.sha256" "$work/$stem.receipt.json" "$output_dir/"
