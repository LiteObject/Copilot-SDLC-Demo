---
description: "Frontend UX and accessibility standards. Use when writing or editing UI components, styles, or markup under src/."
applyTo: "src/**"
---
# Frontend UX & Accessibility Standards

Apply these in addition to the general coding standards when the file renders UI.
If `docs/spec.md` has a **Design** section, treat it as the source of truth for
layout, states, tokens, and accessibility.

## Implement the design

- Build every screen state defined in the Design section: empty, loading, error, and success.
- Use the design tokens (color, typography, spacing) rather than ad-hoc values.
- Respect the documented responsive breakpoints; avoid fixed pixel layouts that break on small screens.

## Accessibility (WCAG)

- Use semantic HTML elements before reaching for ARIA; add ARIA only when semantics are insufficient.
- Every interactive element must be keyboard operable and have a visible focus state.
- Provide accessible names for controls, images (`alt`), and icon-only buttons.
- Maintain a logical focus order and meet the documented color-contrast target (default WCAG AA).
- Do not convey information by color alone.

## Component structure

- Keep presentational markup separate from data fetching and business logic so UI stays unit-testable.
- Keep components small and focused; extract a child component when a view grows multiple responsibilities.
