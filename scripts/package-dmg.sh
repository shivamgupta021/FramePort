#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# The tested app retains its original bundle metadata inside the 0.1 installer.
app_name='FramePort Full Screen'
version='0.1'
distribution=0
if [[ ${1:-} == --release ]]; then
  distribution=1
  shift
fi
qualifier=${1:-}
if (( $# > 1 )) || [[ -n "$qualifier" && ! "$qualifier" =~ '^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$' ]]; then
  print -u2 'Usage: scripts/package-dmg.sh [--release] [qualifier]'
  exit 2
fi
signer=${APP_SIGN_IDENTITY:-${FRAMEPORT_SIGN_IDENTITY:--}}
profile=${APP_NOTARY_PROFILE:-${FRAMEPORT_NOTARY_PROFILE:-}}
if (( distribution )) && [[ -z "$profile" || "$signer" != 'Developer ID Application:'* ]]; then
  print -u2 'Release packaging requires APP_SIGN_IDENTITY (Developer ID Application) and APP_NOTARY_PROFILE.'
  exit 2
fi
if [[ -n "$profile" && "$signer" != 'Developer ID Application:'* ]]; then
  print -u2 'Notarization requires a Developer ID Application signing identity.'
  exit 2
fi

dist_dir=${APP_DIST_DIR:-${FRAMEPORT_DIST_DIR:-dist}}
# Local builds cannot replace an already notarized production artifact.
if (( distribution )); then dist_dir="$dist_dir/release"; fi
mkdir -p "$dist_dir"
dist_dir=${dist_dir:A}
stage=$(mktemp -d "$dist_dir/.second-frame.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
image="SecondFrame-${version}${qualifier:+-${qualifier}}-macOS-arm64.dmg"
mkdir "$stage/volume"
APP_BUNDLE="$stage/volume/$app_name.app" ./scripts/build.sh
ln -s /Applications "$stage/volume/Applications"
cp LICENSE "$stage/volume/"
hdiutil create -quiet -volname "Second Frame" -fs HFS+ -format UDZO -srcfolder "$stage/volume" "$stage/$image"
if [[ "$signer" != "-" ]]; then
  codesign --timestamp --sign "$signer" "$stage/$image"
fi
if [[ -n "$profile" ]]; then
  xcrun notarytool submit "$stage/$image" --keychain-profile "$profile" --wait
  xcrun stapler staple "$stage/$image"
  xcrun stapler validate "$stage/$image"
fi
hdiutil verify -quiet "$stage/$image"
( cd "$stage" && shasum -a 256 "$image" > "$image.sha256" )
mv "$stage/$image" "$stage/$image.sha256" "$dist_dir/"
print "Built $dist_dir/$image"
