# Step 16: fonts on iPhone and iPad — design

Status: 2026-10-28. User: "the ability to choose the font as well as the themes … keep them all" (13 fonts). Calls
marked *(my call)*. Budget ~2%.

## Behaviour
- Settings ▸ Appearance (iPhone sheet, iPad settings) gains **Font**, next to Theme: a list of the 13 fonts, each row
  drawn in its own font with a sample money figure ("£1,284.50"). Default **SF Pro**. Per device, not synced.
- Fonts: SF Pro (system), SF Pro Rounded (system), New York (system serif), Inter, IBM Plex Sans, Source Sans 3,
  Public Sans, DM Sans, Manrope, Atkinson Hyperlegible, Lexend, Source Serif 4, IBM Plex Mono. The 10 non-system
  fonts are bundled (OFL licences included in the app's Acknowledgements) *(my call: regular, medium/semibold and
  bold weights only, to keep the app small)*.
- The choice applies to all app text through the shared design system (MangoUI theme), scaling with Dynamic Type
  (custom fonts via `Font.custom(_:size:relativeTo:)`); **money keeps tabular figures** in every font (monospaced
  digits feature where the font has it; fall back to the system font's tabular digits for figures if a font lacks
  them *(my call)*). Widgets keep the system font *(my call)*.
- The Mac is unchanged.

## Constraints
No figure wraps or truncates in any font at the largest non-accessibility size and accessibility sizes (snapshot
harness renders every route in at least 3 representative fonts: SF Pro, Lexend (wide), IBM Plex Mono (widest));
names truncate in the middle; logic (font catalogue, setting) in MangoUI/BudgetCore with tests.
