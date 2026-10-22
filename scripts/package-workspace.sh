# Sourced by the iOS scripts. Prints the package's own Xcode workspace, creating it if
# needed, so xcodebuild builds the SwiftPM package even when the generated Mango.xcodeproj
# sits next to Package.swift (xcodebuild would otherwise pick the project).
package_workspace() {
  local ws=".swiftpm/xcode/package.xcworkspace"
  if [ ! -f "$ws/contents.xcworkspacedata" ]; then
    mkdir -p "$ws"
    cat >"$ws/contents.xcworkspacedata" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
XML
  fi
  echo "$ws"
}
