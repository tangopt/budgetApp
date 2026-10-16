---
name: install
description: Build Budget in Release and install it to /Applications (runs scripts/install-app.sh). Use when the user types /install or asks to install/update the app.
---

Install the latest main build of Budget into /Applications:

1. Check Budget isn't running: `pgrep -x Budget`. If it is, ask the user to quit it (Budget ▸ Quit) and stop.
2. Make sure the main checkout is on `main` with nothing uncommitted that matters (`git -C /Users/pablo.dimenza/Documents/Code/budget status --short`, ignoring `.worktrees/`).
3. Run `/Users/pablo.dimenza/Documents/Code/budget/scripts/install-app.sh` (timeout 15 minutes).
4. Report the outcome in one or two lines: installed, or the build error. Remind the user they can now open Budget from Applications.
