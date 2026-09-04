## Context
Roadmap M4-04: settings screen (table size override, detection provider, guide speed, debug mirror toggle, practice mode) with persistence.

## Scope
`App/Sources` settings view + a pure, tested `SettingsModel` in `Packages/CueSyncUI` or `CoachKit`; persistence tests.

## Out of scope
New dependencies; TV mode styling.

## Acceptance
- [ ] Every setting round-trips through persistence in a unit test.
- [ ] Mirror `/state.json` reflects the live values.

## Verification
verify:unit; verify:snapshot (advisory) for the screen.

## Device follow-up
none.
