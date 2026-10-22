---
name: install
description: Build Mango in Release and install it to /Applications (runs scripts/install-app.sh). Use when the user types /install or asks to install/update the app.
---

Install the latest main build of Mango into /Applications:

1. Check Mango isn't running: `pgrep -x Mango` (the old name, `pgrep -x Budget`, too). If it is, ask the user to quit it (Mango ▸ Quit) and stop.
2. Make sure the main checkout is on `main` with nothing uncommitted that matters (`git -C /Users/pablo.dimenza/Documents/Code/budget status --short`, ignoring `.worktrees/`).
3. Run `/Users/pablo.dimenza/Documents/Code/budget/scripts/install-app.sh` (timeout 15 minutes).
4. Report the outcome in one or two lines: installed (Developer ID signed when `Config/Signing.local.xcconfig` sets a team; with `--notarise`, for another Mac, also the notarisation status and the `spctl` verdict), or the build error. Remind the user they can now open Mango from Applications.
