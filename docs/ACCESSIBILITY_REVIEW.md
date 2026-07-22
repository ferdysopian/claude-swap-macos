# Accessibility Review Checklist

Manual and semi-automated accessibility audit for the Claude Swap native macOS app. This review is performed at Phase 3 (foundation screens), Phase 4 (full product), and Phase 6 (final sign-off).

**Related:** [`QA_MATRIX.md`](QA_MATRIX.md) P4-8, P6-5; [`DEFINITION_OF_DONE.md`](DEFINITION_OF_DONE.md) item 17.

**Baseline reference:** The Python TUI documents WCAG AA contrast in the user README; the native app must meet or exceed that bar using system accessibility APIs.

---

## Environment Matrix

Run each major screen under these system settings (macOS System Settings → Accessibility / Appearance):

| Setting | Values to test |
|---------|----------------|
| Appearance | Light, Dark |
| Increase Contrast | On / Off |
| Reduce Motion | On / Off |
| Reduce Transparency | On / Off |
| Dynamic Type | Default, Large, Extra Large (via Display → Text size if applicable) |

**Tools**

- VoiceOver (⌘F5)
- Xcode Accessibility Inspector
- Keyboard-only navigation (no mouse/trackpad)
- Optional: Contrast checker on screenshots at 200% zoom

---

## Global Requirements

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| G-1 | All interactive controls have accessibility labels | Inspector shows non-empty label for buttons, toggles, fields | |
| G-2 | Focus order is logical | Tab order follows visual layout; no focus traps except intentional sheets | |
| G-3 | Status not conveyed by color alone | Quota/warning states have text or icon + label | |
| G-4 | Reduce Motion honored | No gratuitous animations; `@Environment(\.accessibilityReduceMotion)` respected | |
| G-5 | Reduce Transparency | Materials/blur degrade gracefully; content remains readable | |
| G-6 | Increase Contrast | Borders/separators visible; selected states distinguishable | |
| G-7 | VoiceOver rotor | Headings, links, buttons navigable by rotor category | |
| G-8 | Help text available | Non-obvious controls have `accessibilityHint` or visible help | |
| G-9 | Error messages announced | Alerts and inline errors trigger accessibility notification | |
| G-10 | Minimum touch/click targets | Controls ≥ 44×44 pt effective hit area where feasible | |

---

## Screen-by-Screen Checklist

### Onboarding

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| O-1 | Step purpose announced | VoiceOver reads step title and body on entry | |
| O-2 | Independent-project disclaimer | Legal/disclaimer text reachable and readable at large sizes | |
| O-3 | Primary action labeled | "Continue" / "Get started" has clear label and hint | |
| O-4 | Skip / back navigation | Keyboard reachable; focus returns correctly | |

### Dashboard

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| D-1 | Usage progress accessibility | Progress views have `accessibilityLabel` + `accessibilityValue` (e.g. "Weekly usage, 72 percent") | |
| D-2 | Active account identification | Current account announced without relying on highlight color alone | |
| D-3 | Refresh / loading state | Live region or announcement when snapshot updates | |
| D-4 | Empty state | Meaningful message when no accounts; action to add account labeled | |
| D-5 | Quarantine / relogin badges | Sentinel states have text labels, not color-only dots | |
| D-6 | Countdown timers | Reset time readable by VoiceOver (absolute or relative, consistent) | |

### Accounts

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| A-1 | Search field | Labeled "Search accounts"; results count announced | |
| A-2 | Account rows | Each row: name, email (privacy-appropriate), slot number, status | |
| A-3 | Switch action | Keyboard shortcut or menu item with label "Switch to …" | |
| A-4 | Destructive actions | Remove/move reachable by keyboard; confirmation sheet names exact account | |
| A-5 | Add token sheet | Secure field uses `SecureField`; label "API token" or equivalent; not echoed by VoiceOver | |
| A-6 | Sheet focus trap | Focus confined to sheet while open; Escape dismisses where appropriate | |

### Automation

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| AU-1 | Sliders / steppers | VoiceOver announces current numeric value on change | |
| AU-2 | Toggle states | "On" / "Off" announced for auto-switch enable | |
| AU-3 | Help text | Threshold explanations readable at large Dynamic Type | |

### Activity

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| AC-1 | Timeline items | Each event has date, action type, account (no credential substrings) | |
| AC-2 | Rotor navigation | Events list navigable as list or table | |
| AC-3 | Filter controls | If present, labeled and keyboard accessible | |

### Menu Bar Extra

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| M-1 | Menu bar icon | `accessibilityLabel` on status item (e.g. "Claude Swap, account 2 active") | |
| M-2 | Popover content | Compact mode still readable; not clipped at large text sizes | |
| M-3 | Quick switch | Menu items keyboard navigable; shortcuts documented | |
| M-4 | Open main window | Action labeled; works from keyboard | |

### Settings

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| S-1 | Grouped sections | `Form` / `Section` headers exposed to VoiceOver | |
| S-2 | Toggles announce state | Launch at login, notification prefs | |
| S-3 | About / version | Version string readable; links keyboard activatable | |

### Error and Recovery

| # | Check | Pass criteria | Evidence |
|---|-------|---------------|----------|
| E-1 | Helper crash screen | Error explained in plain language; recovery action labeled | |
| E-2 | Keychain unavailable | Actionable guidance; not color-only warning | |
| E-3 | Bridge protocol mismatch | Version mismatch message readable; no raw JSON dump as only feedback | |
| E-4 | Alert buttons | Default and cancel roles correct; destructive buttons labeled | |

---

## Keyboard Navigation Pass

Perform a full session without pointer input:

| # | Flow | Steps | Pass |
|---|------|-------|------|
| K-1 | Launch to switch | Tab through onboarding (if any) → dashboard → select account → switch | |
| K-2 | Add token | Open sheet → type token → submit → dismiss | |
| K-3 | Remove account | Navigate to account → remove → confirm/cancel in sheet | |
| K-4 | Menu bar only | Operate entirely from menu bar extra | |
| K-5 | Reopen window | Close main window → reopen from menu bar / Dock | |
| K-6 | Settings round-trip | Open settings → change toggle → return to dashboard | |

---

## Automated Accessibility Tests (XCUITest)

When UI tests exist, verify:

| Test | Assertion |
|------|-----------|
| `testDashboardAccessibilityIdentifiers` | Key views expose identifiers for automation |
| `testOnboardingLabels` | AX labels non-empty on primary controls |
| `testAccountsListAccessibility` | List rows have combined accessibility elements |
| `testAddTokenSecureField` | Secure field element type correct |

Automated tests **supplement** but do not replace VoiceOver manual pass.

---

## VoiceOver Script (Phase 6)

1. Enable VoiceOver. Open Claude Swap fresh (or reset onboarding).
2. Complete onboarding using VO + keyboard only; note any unlabeled controls.
3. On Dashboard: navigate all usage meters; trigger refresh; verify announcement.
4. Open Accounts: search, select row, invoke switch from menu.
5. Open Add Token sheet: verify secure field behavior; cancel.
6. Open Automation: adjust one slider; verify value announcement.
7. Open Activity: read three timeline entries via rotor.
8. From menu bar: open popover, quick-switch, open main window.
9. Enable **Reduce Motion** and **Increase Contrast**; repeat steps 3–5.
10. Record failures with screen name, VO text heard, expected behavior.

---

## Severity Rubric

| Severity | Example | Action |
|----------|---------|--------|
| **Blocker** | Cannot switch accounts with VoiceOver; secure field reads token aloud | Fix before release |
| **Major** | Progress bar value not announced; destructive action color-only | Fix before RC |
| **Minor** | Hint text missing on obscure control | Fix or document workaround |
| **Enhancement** | Additional keyboard shortcuts | Backlog |

---

## Sign-off Template

| Reviewer | Date | Build / commit | Environments tested | Blockers | Approved |
|----------|------|----------------|---------------------|----------|----------|
| QA | | | Light/Dark/Contrast/Motion | | ☐ |
