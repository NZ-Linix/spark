#!/bin/sh
# Archives the app and uploads it to TestFlight for internal testing. The build number is the UTC
# date and time, such as 20261125.1442, so every upload sorts above the one before it.
set -eu
cd "$(dirname "$0")"

team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig)
build=$(date -u +%Y%m%d.%H%M)
mkdir -p build
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
EOF

xcodegen generate
rm -rf build/Spark.xcarchive build/export
echo "Archiving build $build"
xcodebuild archive -project Spark.xcodeproj -scheme Spark -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Spark.xcarchive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" > build/archive.log 2>&1 \
  || { tail -30 build/archive.log; exit 1; }
echo "Uploading build $build"
xcodebuild -exportArchive -archivePath build/Spark.xcarchive -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates > build/upload.log 2>&1 \
  || { tail -30 build/upload.log; exit 1; }
echo "Uploaded build $build"
