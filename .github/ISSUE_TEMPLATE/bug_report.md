---
name: Bug report
about: A touchpad button does nothing, the lights are wrong, or the bridge cannot find the call
labels: bug
---

**What happens, and what did you expect?**

**Versions** (this project depends on all of them)

- Dell Optimizer: <!-- PowerShell: (Get-AppxPackage DellInc.DellOptimizer).Version -->
- Yandex Telemost: <!-- right-click YandexTelemost.exe > Properties > Details -->
- Windows: <!-- winver -->
- This project: <!-- release tag or commit; see VERSION.txt -->
- Laptop model:

**Logs** from `%LOCALAPPDATA%\TelemostTouchpad\logs\` (`fake-teams.log`, `telemost-bridge.log`, `*.err.log`),
the lines around the problem. Please remove any `tokenRefresh` / `token=` values first.

**Which of these is true?**

- [ ] `fake-teams.log` shows `[++] ... app='Dell Optimizer'` (Optimizer connects)
- [ ] pressing a touchpad button shows `touchpad '...' -> forwarded` in `fake-teams.log`
- [ ] `telemost-bridge.log` shows `in call` during a call (or `no call window`)
