# Dashboard window — build 2113

The footer's public Open as Window button (Shift-Command-O), app menu command and reopening the installed app from Finder present the existing compact dashboard in a normal titled, closable, movable and minimizable window. The menu-bar mascot keeps its original popover. The window uses the same DashboardModel, DashboardUIState, actual usage snapshot and privacy display state; it is not the fixture-based review window or a separate large usage dashboard.

People can keep the dashboard visible while working in another app and move it to another monitor. Standard window close/minimize commands are available. No collector, hidden control endpoint, playback script, synthetic metric, permission or account is introduced. The explicit production window is a user-facing product feature, not a claim that the native AXPopover was incorrectly implemented.

Visibility tracks the popover and normal window separately. Collection switches to its existing open cadence when the first surface opens and returns to its existing closed cadence when the last surface closes or is minimized. Reopening an already visible window cannot multiply timers. Mascot open/close notifications are scoped to their own surface.

Validation before installation: all 373 tests passed (93 XCTest, 66 usage, 205 core, 9 dashboard). Three added lifecycle cases cover simultaneous surfaces, repeated events and minimize/restore. Release/signature, installation, actual native clicks and Retina capture are recorded separately after verification; compilation alone does not establish live interaction or image quality.
