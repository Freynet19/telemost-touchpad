# Stops the Telemost <-> Dell Collaboration Touchpad bridge (both programs).
Stop-Process -Name 'telemost-bridge', 'fake-teams' -ErrorAction SilentlyContinue
