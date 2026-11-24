#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Prereleases may append a qualifier to the app's marketing version.
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
qualifier=${1:-}
if (( $# > 1 )) || [[ -n "$qualifier" && ! "$qualifier" =~ '^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$' ]]; then
  print -u2 'Usage: scripts/package-dmg.sh [alpha.1]'
  exit 2
fi
signer=${FRAMEPORT_SIGN_IDENTITY:--}
profile=${FRAMEPORT_NOTARY_PROFILE:-}
if [[ -n "$profile" && "$signer" != 'Developer ID Application:'* ]]; then
  print -u2 'Notarization requires a Developer ID Application signing identity.'
  exit 2
fi

dist_dir=${FRAMEPORT_DIST_DIR:-dist}
mkdir -p "$dist_dir"
dist_dir=${dist_dir:A}
stage=$(mktemp -d "$dist_dir/.frameport.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
image="gta60fps-${version}${qualifier:+-${qualifier}}-macOS-arm64.dmg"
mkdir "$stage/volume"
FRAMEPORT_BUNDLE="$stage/volume/gta60fps.app" ./scripts/build.sh
ln -s /Applications "$stage/volume/Applications"
hdiutil create -quiet -volname gta60fps -fs HFS+ -format UDZO -srcfolder "$stage/volume" "$stage/$image"
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
