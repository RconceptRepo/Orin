# ORIN V1 - UI / UX DESIGN SYSTEM SPECIFICATION

This specification is the immutable UI contract for Orin V1 unless intentionally revised.

## Design Philosophy

The UI should feel like a mix of Apple Reminders, Apple Calendar, Apple Notes, Things 3, Arc Browser, and Granola.

Keywords: calm, minimal, fast, elegant, professional, focused, premium.

Avoid dashboard clutter, excessive gradients, excessive animations, bright neon colors, multiple floating panels, and complex menus.

## Theme Support

Mandatory support:

- Light Mode
- Dark Mode
- System Mode

System Mode follows macOS appearance and changes instantly without restart.

## Primary Color Palette

Light Mode:

- Background Primary: `#F8F9FB`
- Background Secondary: `#FFFFFF`
- Sidebar Background: `#F2F4F7`
- Card Background: `#FFFFFF`
- Primary Text: `#111827`
- Secondary Text: `#6B7280`
- Borders: `#E5E7EB`

Dark Mode:

- Background Primary: `#111827`
- Background Secondary: `#1F2937`
- Sidebar Background: `#0F172A`
- Card Background: `#1E293B`
- Primary Text: `#F9FAFB`
- Secondary Text: `#9CA3AF`
- Borders: `#334155`

Brand accent:

- Primary Accent: `#2563EB`
- Hover: `#1D4ED8`
- Pressed: `#1E40AF`

Use accent only for primary actions, links, active navigation, and selected states. Never use it on large surfaces.

Priority colors:

- P0 Critical: `#DC2626`, badge `#FEE2E2`
- P1 High: `#EA580C`, badge `#FFEDD5`
- P2 Medium: `#2563EB`, badge `#DBEAFE`
- P3 Low: `#6B7280`, badge `#F3F4F6`

Status colors:

- Success: `#16A34A`
- Warning: `#F59E0B`
- Error: `#DC2626`
- Info: `#2563EB`

## Layout Rules

- Desktop first.
- Minimum supported width: `1280px`.
- Recommended width: `1440px+`.
- Sidebar: `30%`.
- Content area: `70%`.
- Never use centered content layouts for primary app screens.
- Always use available screen space.

## Navigation Design

Sidebar navigation item height: `48px`.

Active state:

- Accent background
- Accent left border
- Bold text

Hover state:

- Subtle background only

## Typography

Font family: system default SF Pro. Fallback: Inter.

- Page Title: `28px`
- Section Title: `20px`
- Card Title: `16px`
- Body Text: `14px`
- Caption: `12px`

## Shape, Elevation, And Spacing

Border radius:

- Cards: `16px`
- Buttons: `12px`
- Inputs: `10px`
- Badges: `999px`

Shadows:

- Light Mode: `0 1px 3px rgba(0,0,0,.08)`
- Dark Mode: `0 1px 4px rgba(0,0,0,.35)`

Use subtle shadows only.

Cards:

- All major content must be card-based.
- Card padding: `20px`.
- Gap: `16px`.

Examples: task details, meeting summary, AI suggestions, calendar events, vault entries.

## Buttons

- Primary: filled accent blue.
- Secondary: outline.
- Danger: red.

Never use more than one primary and one secondary button in the same action group.

## Task List Design

Each task row:

- Height: `56px`
- Contains checkbox, task name, priority badge, due date, 3-dot menu.

Subtasks:

- Indented `24px`
- Subtle connector line.

## Calendar Design

Calendar layout modes:

- Month View
- Week View
- Agenda View

Default: Agenda View.

Meeting cards are rounded, compact, and use a colored left border.

## Meeting Recording Widget

Floating widget:

- Size: `220px x 52px`
- Rounded pill design
- Draggable anywhere
- Always on top

States:

- Listening: red dot pulse
- Paused: amber
- Stopped: gray

## AI Suggestion Cards

Use a dedicated card style.

Header: `AI Suggestion`.

Actions:

- Accept
- Edit
- Decline

Color: soft blue accent. Never use chatbot bubbles.

## Vault Design

Apple Passwords inspired.

Cards contain:

- Service Name
- Username
- Hidden Secret

Actions:

- Copy
- Edit
- Delete

Sensitive values are hidden by default.

## Animations

Duration: `200ms-250ms`.

Use fade, slide, and scale. Avoid bounce, flashy motion, and excessive parallax.

## Responsiveness

Primary targets:

- MacBook Air
- MacBook Pro
- iMac
- Studio Display

Breakpoints:

- Compact: `1280px`
- Standard: `1440px`
- Large: `1728px+`

## Accessibility

Support:

- Dynamic Type
- VoiceOver
- Keyboard navigation
- High contrast

Minimum contrast ratio: `4.5:1`.

## Empty States

Every empty screen must include:

- Simple illustration/icon
- Explanation
- Primary action

Example: "No tasks for today" with button "Create Task".

## UX Golden Rules

1. Every important action is 3 clicks or fewer.
2. Every major workflow is 30 seconds or fewer.
3. Never hide critical actions.
4. No silent failures.
5. Always show status feedback.
6. Use progressive disclosure.
7. Keep the interface calm.
8. Prioritize execution over analytics.
9. Avoid modal overload.
10. Make Orin feel native to macOS.
