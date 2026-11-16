# PerfMoon app icon

The icon combines four bars with a pulse line and a live dot. The menu bar glyph in `PerfMoon/StatusItem/StatusGlyph.swift` uses the same bar proportions and draws live readings without the pulse line.

| File | Purpose |
| --- | --- |
| `AppIcon.icon/` | Editable Icon Composer document. |
| `AppIcon.icon/Assets/Bars.svg` | Four rounded bars in a white-to-blue gradient. |
| `AppIcon.icon/Assets/Pulse.svg` | Cyan pulse line and live dot. |
| `Reference.svg` | Flat reference image; the app build does not use it. |

The artwork uses a 1024 × 1024 canvas. The four bars are 120 px wide with 72 px gaps and align along the bottom. The background is dark graphite blue. Icon Composer adds Liquid Glass lighting and handles Default, Dark, Clear, and Tinted appearances.

## Editing and building

1. Open `Design/Icon/AppIcon.icon` in Icon Composer. The **Pulse** group should be above **Bars**. Preview the default and tinted appearances after editing.
2. From the repository root, copy the edited icon into the app's source tree and build:

   ```sh
   ditto Design/Icon/AppIcon.icon PerfMoon/AppIcon.icon
   scripts/build.sh
   ```

3. Check the resulting icon in Finder and in the Dock while the main window is open.
