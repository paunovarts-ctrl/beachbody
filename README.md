# Beach Body Map

A live sun-bed and parasol reservation and operations map for **Beach Materada, Poreč**, Croatia. It installs to a phone's home screen, runs with no signal, and needs no backend and no build step.

## What it does

- **Live beach map** built on a real drone photo of the shoreline, with every sun bed and parasol placed as a tappable spot.
- **QR check-in** — print a marker for each physical spot on the sand; staff scan to check guests in or out, or set a spot free, on hold, or in for service.
- **Zones** you draw yourself, with per-zone counts and filtering.
- **Morning setup checklist** so opening the beach each day is a checklist, not a puzzle.
- **Day & takings** — check-ins, peak occupancy and revenue tracked automatically, with a one-tap end-of-day close.
- **Croatian / English**, switchable at any time.
- **Built-in guide** covering every screen and control.

## Installing it on a phone

The app is a PWA. Served over https it installs to the home screen, opens without browser chrome, and keeps working offline — the shell and the beach photo are cached on first load.

- **Android / Chrome** — an **Install** button appears in the header once the browser confirms it is installable.
- **iPhone / Safari** — Safari gives web pages no way to trigger installation, so the same button opens the three steps it actually takes (Share → Add to Home Screen → Add).

Offline is a hard requirement rather than a nicety: Materada does not have dependable coverage, and all of the app's data lives in the browser anyway.

## Running it locally

```bash
python3 -m http.server 8145
```

Then open http://localhost:8145.

Opening `index.html` straight off the disk works for a look around, but two things need a real address:

- **the camera** — browsers only hand it over on `https://` or `localhost`, so on `file://` the scanner explains that and falls back to typing the code
- **the service worker**, and therefore offline mode and installing

`localhost` counts as secure, so the command above gives you the full app.

Demo login: operator `Admin1`, passcode `Admin`.

## Files

- `index.html` — the app: markup, styles and logic in one file
- `assets/beach.jpg` — the drone photo the map is built on
- `manifest.webmanifest`, `sw.js`, `icons/` — what makes it installable and offline-capable
- `beach-body-map.html` — redirect, kept so old links still work

## A note on the login

The gate keeps the beach's numbers off a screen a guest could pick up. It is not a security boundary: everything runs in the browser, so anyone who can open the page can read the data. Real accounts would need the cloud endpoint under **Day › Sync**.
