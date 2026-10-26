#!/bin/bash
# Step 6 (sharing levels, Task 9): every data write the Mac app makes runs as the signed-in user, checked against
# their permissions (`DatabaseWriter.write(_ area:origin:_:)` in App/AppEnvironment.swift, over `ActorWrite.perform`).
# Lists the App/ lines that write to the database any other way (`dbQueue.write { … }`, `.write(body)`,
# `writeWithoutTransaction`, `inDatabase`, …) and exits non-zero; prints "actor writes OK" when there are none.
# Allowed outside the check: App/AppEnvironment.swift (the helpers and launch upkeep, as the admin),
# App/Snapshots/ (the snapshot harness's own data), App/Auth/ (sign-in bookkeeping) and App/Sync/.
set -uo pipefail
cd "$(dirname "$0")/.."
if ! found="$(find App -name '*.swift' -print0 | sort -z | xargs -0 perl -ne '
    # A write call whose first argument is not an area (`.write(.property)`, `.write(area, …)`), and not a file write
    # or a view model calling its own (actor) write helper (`self.write(…)`).
    if ($ARGV !~ m{^App/(AppEnvironment[.]swift$|Snapshots/|Auth/|Sync/)} && $_ !~ m{^\s*//}
        && /(?<!\bself)[.](write|writeWithoutTransaction|barrierWriteWithoutTransaction|unsafeReentrantWrite|asyncWrite|inDatabase)\s*([{]|[(](?!\s*([.][a-zA-Z]|area\b|to:|contentsOf:|Data[(])))/) {
        print "$ARGV:$.: $_";
    }
    close ARGV if eof;')"; then
  echo "check-actor-writes: the scan failed" >&2
  exit 2
fi
if [ -n "$found" ]; then
  echo "$found"
  echo "Writes that bypass the actor (use dbQueue.write(<area>) { … }): $(echo "$found" | wc -l | tr -d ' ')" >&2
  exit 1
fi
echo "actor writes OK"
