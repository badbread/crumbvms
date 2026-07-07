#!/usr/bin/env bash
# Compile the iOS app on the Mac (the Mac host) over SSH.
#
# No code sync: the Mac NFS-mounts the same repo ($MAC_REPO == this checkout), so
# whatever is committed/saved is what builds. Default is an UNSIGNED compile check
# (proves it builds); a real device/TestFlight build needs signing set up first
# (free Apple ID = 7-day on-device; $99 Apple Developer Program = TestFlight).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "iOS build on $MAC (scheme Crumb, unsigned compile check)"
ssh "$MAC" "cd '$MAC_REPO/apps/ios' && /usr/bin/xcodebuild \
  -scheme Crumb -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build" || die "iOS build failed"
ok "iOS app compiled (unsigned). Signed device/TestFlight build is a separate step."
