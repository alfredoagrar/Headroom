---
id: 002
title: Absolute reset dates
status: implemented
owner: "@alfredoagrar"
created: 2026-09-25
depends-on: [001]
---

# 002 · Absolute reset dates

## Problem
A countdown like "6d 0h" forces mental math to know *which day* a weekly limit resets.

## Goals
- Show the absolute reset date under every bar, in addition to the countdown.

## User experience
```
Weekly                 3%   6d 0h
█░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
📅 Resets Thu Oct 1, 12:59
```
Formats: `today, HH:mm` · `tomorrow, HH:mm` · `<weekday> <day> <month>, HH:mm` · year appended when different. 24-hour clock, local time zone. Refreshes every minute.

## Design
`ResetFormatter.absolute(_:now:calendar:)` in `Core/Models/Formatting.swift`; rendered in `LimitRow`.

### Security & privacy
None.

## Acceptance criteria
- [x] AC1 — Same-day, next-day, same-year and next-year formats covered by `absoluteResetDates` test.
- [x] AC2 — Date line appears for every window that has `resetsAt`.
