# Using an unreleased version of connlib

Normally, firezone-apple uses a released connlib version, available as a zip
file hosted at a URL.

If we're hacking on connlib, we'll need the app to build off a local version of
connlib. To use connlib from a local repository, we can do this:

- Setup
   - In the connlib repo:
       - Edit apple/build-xcframework.sh:
           - Comment out or remove all lines after `echo "Computing checksum"`,
             so no zip file is created -- we'll use the unzipped
             Connlib.xcframework
           - Add `rm -rf ./Connlib.xcframework` before the
             `xcodebuild -create-xcframework` command
           - If we're going to be building only for macOS, we can remove
             the builds for iOS and Simulator.
           - After these changes, the script would look something like this:
             ~~~
             #!/bin/bash
             set -ex

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
             ~~~

	   - If we like, we can commit this change as "DO_NOT_PUSH" or
	     something like that

   - In our firezone-apple repo:
       - Edit FirezoneKit/Package.swift
	   - In the binaryTarget named "Connlib"
	       - Remove the "url" and "checksum" keys
	       - Add a "path" key with value as the path to
	         Connlib.xcframework. The path must be relative to the folder
                 containing the Package.swift.
               - After doing this, the Package.swift's `targets` section's
                 initial lines would look something like this:
                 ~~~
                   targets: [
                     .binaryTarget(
                       name: "Connlib",
                       path: "../../connlib/apple/Connlib.xcframework/"
                     ),
                 ~~~
	   - If we like, we can commit this change as "DO_NOT_PUSH" or
	     something like that
       - Open Firezone.xcodeproj in Xcode
            - File > Packages > Resolve Package Versions

- Building
   - In the connlib repo:
       - Run
         ~~~
         cd apple
         cargo build # Generates swift-bridge headers
         ~~~
       - Open apple/connlib.xcodeproj (or clients/apple/connlib.xcodeproj) in Xcode
       - Build for macOS / Generic iOS (Calls ./build-rust.sh)
       - Build the framework in the command line:
         ~~~
         cd apple
         ./build-xcframework.sh # Creates ./Connlib.xcframework
         ~~~
   - In the firezone-apple repo:
       - Open Firezone.xcodeproj in Xcode
       - Build / run the "Firezone" target for macOS / iOS
