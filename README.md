# Beach Body Map

A live sun-bed and parasol reservation and operations map for **Beach Materada, Poreč**, Croatia — built as a single self-contained HTML file with no backend, no build step, and no install.

## What it does

- **Live beach map** built on a real drone/satellite photo of the beach, with every sun bed and parasol placed as a tappable spot.
- **QR check-in** — print a marker for each physical spot on the sand; staff scan to check guests in or out, or set a spot free, on hold, or in for service.
- **Zones** you draw yourself, with per-zone counts and filtering.
- **Morning setup checklist** so opening the beach each day is a checklist, not a puzzle — spots are what's fixed, not the furniture.
- **Day & takings** — check-ins, peak occupancy, and revenue tracked automatically, with a one-tap end-of-day reset.
- **Croatian / English** interface, switchable at any time.
- **Built-in guide** covering every screen and control.
- Works on phone, tablet, or a counter PC, offline, with no accounts to manage.

## Running it

This is a single HTML file with everything (markup, styles, and JavaScript) inline. To try it locally:

```bash
python3 -m http.server 8000
# then open http://localhost:8000/beach-body-map.html
```

Or just open `beach-body-map.html` directly in a browser.

Demo login: operator `Admin1`, passcode `Admin`.

## Files

- `beach-body-map.html` — the app.
