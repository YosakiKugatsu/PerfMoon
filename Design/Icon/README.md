# PerfMoon app icon

One identity across the app icon and the menu bar: four bars of uneven height and a thin
pulse line that rides above their tops and ends in a "live" dot. The menu bar glyph
(`PerfMoon/StatusItem/StatusGlyph.swift`) draws the same four bars live, with the same
2.5 : 1.5 bar-to-gap ratio, but without the pulse. The pulse line is what separates the
brand mark from the live data.

## Files

| File | Purpose |
|---|---|
| `AppIcon.icon/` | Icon Composer document (`icon.json` + `Assets/`) |
| `AppIcon.icon/Assets/Bars.svg` | Back group: four white-to-ice-blue rounded bars |
| `AppIcon.icon/Assets/Pulse.svg` | Front group: cyan pulse polyline (`#5AC8FA`, 36 px) with a white-cored end dot |
| `Reference.svg` | Flattened reference of the intended look. Not used by the build. |

## Specification (1024 × 1024 canvas)

- **Background:** deep graphite blue. The document uses `automatic-gradient` with base
  `#1B263F`. If it looks too flat, use a linear gradient from `#2B3245` (top) to `#0C1630`
  (bottom), as in `Reference.svg`.
- **Bars group (back):**
  - Bars are 120 px wide with 72 px gaps and corner radius 36.
  - Bottoms are aligned at y = 792; heights are 221, 355, 274, and 442.
  - Liquid Glass on, neutral shadow at 50%, translucency 0.5.
- **Pulse group (front):**
  - Polyline through `104,572 → 224,499 → 416,365 → 608,446 → 800,278`.
  - End dot: radius 40, with a white core of radius 16.
  - Liquid Glass on, neutral shadow at 50%, translucency 0.3.
- **Appearances:** Default, Dark, Clear, and Tinted all use the system's automatic
  treatment. No per-appearance artwork.

## Build and preview the icon

1. **Check that the document renders.** Use the `ictool` bundled with Icon Composer:

   ```sh
   IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
   "$IC" Design/Icon/AppIcon.icon --export-image --output-file build/icon-default.png \
     --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
   "$IC" Design/Icon/AppIcon.icon --export-image --output-file build/icon-tinted-dark.png \
     --platform macOS --rendition TintedDark --width 1024 --height 1024 --scale 1
   ```

   Compare `build/icon-default.png` with `Reference.svg`.
2. **Open it in Icon Composer** (File ▸ Open… ▸ `Design/Icon/AppIcon.icon`) and confirm:
   - The sidebar lists two groups, **Pulse** above **Bars**.
   - Liquid Glass is on for both.
   - The background matches the spec.

   If you adjust anything, change only the values listed above, then save.
3. **If the document doesn't open,** rebuild it in the GUI and save it as
   `Design/Icon/AppIcon.icon`:
   1. Create a new document.
   2. Set the background to the linear gradient in the spec.
   3. Drag in `Bars.svg`, then `Pulse.svg`, each as its own group, with Pulse on top.
   4. Apply the group settings from the spec.
4. **Add it to the app.** Copy the document into the synchronized source folder:

   ```sh
   ditto Design/Icon/AppIcon.icon PerfMoon/AppIcon.icon
   ```

   The target already sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, and
   `Assets.xcassets` contains no `AppIcon` set, so there's no name conflict. Rebuild, then
   check the icon in Finder and in the Dock while the main window is open.
