#!/bin/bash
set -ex

for sdk in macosx iphoneos iphonesimulator; do
  echo "Building for $sdk"

  xcodebuild archive \
    -scheme Connlib \
    -destination "generic/platform=$sdk" \
    -sdk $sdk \
    -archivePath ./connlib-$sdk \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
done

xcodebuild -create-xcframework \
  -framework ./connlib-iphoneos.xcarchive/Products/Library/Frameworks/connlib.framework \
  -framework ./connlib-iphonesimulator.xcarchive/Products/Library/Frameworks/connlib.framework \
  -framework ./connlib-macosx.xcarchive/Products/Library/Frameworks/connlib.framework \
  -output ./Connlib.xcframework

echo "Build successful. Removing temporary archives"
rm -rf ./connlib-iphoneos.xcarchive
rm -rf ./connlib-iphonesimulator.xcarchive
rm -rf ./connlib-macosx.xcarchive

echo "Computing checksum"
touch Package.swift
zip -r -y Connlib.xcframework.zip Connlib.xcframework
swift package compute-checksum Connlib.xcframework.zip > Connlib.xcframework.zip.checksum.txt

rm Package.swift
rm -rf Connlib.xcframework
