# For more info:
# https://github.com/firezone/firezone-apple/blob/main/USING_UNRELEASED_CONNLIB.md

#!/bin/bash
set -ex

echo $SRC_ROOT

for sdk in macosx; do
  echo "Building for $sdk"

  xcodebuild archive \
    -scheme Connlib \
    -destination "generic/platform=$sdk" \
    -sdk $sdk \
    -archivePath ./connlib-$sdk \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
done

rm -rf ./Connlib.xcframework
xcodebuild -create-xcframework \
  -framework ./connlib-macosx.xcarchive/Products/Library/Frameworks/connlib.framework \
  -output ./Connlib.xcframework

echo "Build successful. Removing temporary archives"
rm -rf ./connlib-macosx.xcarchive
