# Barber 33 — Poreč

Public site for **Barber 33**, a walk-in barbershop in Poreč. One file, no
build step, no framework — `index.html` is the whole site.

Deployed alongside the beach app, so it lives at `/barber33/`.

## Before it goes live

Two places hold everything the shop still has to confirm. Both are marked
`FILL` in `index.html`:

1. **`SHOP`**, at the top of the script at the bottom of the file — phone,
   street address, Instagram handle. Every call button, every maps link and
   the contact block read from here, so it is the only place to type them.
   A field left empty is handled rather than faked: the call buttons
   disappear instead of offering a dead link, and the contact row keeps
   saying *upiši broj* so nobody ships the site without noticing.
2. **The JSON-LD block** in `<head>` — the same address and phone again, this
   time for Google's local results. Keep it in step with `SHOP`.

Worth a second pair of eyes from the shop as well:

- the prices and durations in the **Cjenik** section
- the **opening hours table** — the open/closed badge at the top of the page
  is computed from its `data-open` / `data-close` attributes, so an hour
  wrong there is wrong in two places
- the quiet-times note beside the hours
- *Hrvatski i engleski* in the **Što radimo** cards

## Photos

Drop `shop-1.jpg` … `shop-5.jpg` into `assets/` and the gallery picks them
up — the first is the large tile. Until a file exists, that tile falls back
to a drawn panel rather than showing a broken image, so the row is safe to
ship half-finished.

Roughly 1600px on the long edge is plenty; they are displayed as squares.

## How it behaves

- **Croatian is the page**, English lives in `data-en` attributes beside it.
  A phone not set to Croatian gets English on its first visit, and whatever
  anyone picks with the EN/HR button wins from then on.
- **The open/closed badge** reads the hours table and Poreč's clock, not the
  visitor's — in August a good share of the people reading this are on a
  phone still set to Munich. Closed is never just "closed": it says when the
  door opens again.
- **The call bar** on a phone keeps the number and the directions within
  thumb reach the whole way down the page.

## Running it locally

```bash
python3 -m http.server 8146
```

Then <http://localhost:8146/barber33/>.

## Assets

`icons/` and `assets/share-card.jpg` are generated, not drawn by hand. The
barber pole and the share card come out of `tools/make-brand.py`, so a colour
change is a re-run rather than a redraw:

```bash
pip install Pillow && python3 barber33/tools/make-brand.py
```

The palette constants at the top of that script are the same values as the
CSS custom properties in `index.html`; change both together.
