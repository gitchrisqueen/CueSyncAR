# CueSync AR — app icon

## Concept

The projected aim line on green cloth: the one moment that is the app. A cue
ball, nearest and largest, fires the amber aim line at a ghost ball drawn as an
outline (exactly how the live view draws the predicted contact) tangent to a
blue object ball. Four shapes and one line, no text. Everything the app
overlays on a real table is here, and nothing else.

`cuesync-icon.svg` is the single source of truth. The PNGs in
`App/Resources/Assets.xcassets/AppIcon.appiconset/` are build products of it
and are never edited by hand.

## Palette

All values are the app's own tokens, so the icon and the HUD agree:

| Role                    | Hex       | Source                                   |
| ----------------------- | --------- | ---------------------------------------- |
| Cloth (mid)             | `#1E6B45` | `TableSceneView.feltColor`               |
| Cloth (lit / shadowed)  | `#2E8F5E` / `#10402A` | lamp gradient around the cloth tone |
| Aim line                | `#F5A623` | `Theme.cueAmber`                         |
| Object ball             | `#4A90D9` | `Theme.chalkBlue` (the 2-ball)           |
| Cue ball                | `#F5F2E9` | `Theme.ballWhite`                        |
| Ghost ball              | `#FFFFFF` at 85 % stroke / 12 % fill | as in the app       |
| Dark appearance cloth   | `#1B5C3C` / `#123F2A` / `#081F14` | `appearances/dark.css` |

Why green and amber: cloth green is the ground the whole app draws on, and
amber is the colour the app already uses for the aim line, so the icon is a
literal crop of the product rather than a new brand. Blue for the object ball
is the theme's third accent and the only ball colour that reads against green
without fighting the amber.

## Appearances

Xcode 26 / iOS 26 takes one 1024 × 1024 image per appearance and derives every
other size itself, so the icon set is three files:

- `AppIcon.png` — default, opaque (App Store requires no alpha).
- `AppIcon-dark.png` — same drawing on a dim-room cloth (`appearances/dark.css`).
- `AppIcon-tinted.png` — grayscale on a transparent background; iOS supplies
  the ground and the user's tint (`appearances/tinted.css`).

The variants are CSS overrides applied to the master by `rsvg-convert
--stylesheet`; they never fork the drawing.

## Regenerate

```
Scripts/render-icon.sh
```

Needs `rsvg-convert` (`brew install librsvg`) and, for the preview sheet only,
`python3` with Pillow. Writes the three PNGs and `Design/preview.png`, then
fails if the default icon has an alpha channel. Nothing in the Swift packages
depends on any of this.

## Legibility at 40 px

`preview.png` shows the 1024 master Lanczos-downsampled to 180 / 120 / 80 /
60 / 40 px on light and dark grounds (that is how iOS produces the small
sizes from the single source), plus the iOS squircle mask and the two
appearance variants. At 40 px the icon is a white dot, an amber diagonal and
a blue dot. The ghost ring is the first thing to go: it is still a clear
ring at 60 px and a one-pixel halo around the end of the line at 40 px. It
does not break the three-shape read, but it is the one element that is
decoration rather than signal at that size, and the one to drop if the
40 px cell in `preview.png` looks busy. Anything finer than that (the
line's glow, the ball shading) was designed to disappear rather than to be
required.

Safe area: all four shapes sit inside the iOS rounded-rect mask with margin;
the corners hold only cloth.
