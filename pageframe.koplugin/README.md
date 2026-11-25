# Page Frame

A decorative frame around the page while you read, for KOReader.

- **Bring your own frame:** put a frame image in `koreader/frames/` and it is drawn on every
  page. No frame image comes with the plugin; see [Add your frames](#add-your-frames).
- The frame is drawn on every page in soft grey ink, and it works on greyscale Kindles and in
  night mode.
- **Your KOReader margins and font are kept.**
  - **Margins:** a side is widened only when your margin there would let text touch the frame,
    and only as far as needed. Your own margins come back exactly when the frame is hidden.
  - **Font:** your font is used as you set it. **Font with the frame** is an opt-in that sets a
    matching font (such as the included **Cormorant Garamond**, italic if you like) while the frame
    is shown, without changing your setting.

## The menu

Open the top menu, go to the **Tools** tab (the wrench), then **Page frame**. It's there both in
the file browser and while you read, next to your other plugins. While reading, the same menu is
also in the **typeset** tab (the "A"), next to the book's margins and font. To switch the whole plugin off,
use Tools → More tools → Plugin management → User plugins → Page Frame.

| Item | What it does |
|---|---|
| **Show page frame** | Turns the frame on or off. Off also drops the frame's font and gives the book its own margins back. Your frame and settings are kept for when you switch it on again. |
| Your frames | Which frame to show. The choice applies to every book. Until you pick one, the first frame (by name) is used. Picking a frame switches it on. With no frames installed, a hint says where to put them. |
| **Darkness** | Soft (default), Normal or Bold ink. |
| **Crisp lines** | Sharpens the frame's lines and deepens its shading, so soft artwork looks crisp on e-ink. On by default; turn it off for frames that are already clean line art. |
| **Keep text inside the frame** | Keeps your KOReader margins, and widens a side only as far as needed so the text never touches the drawing. On by default. Turn it off to use your margins as they are, even if text runs over the frame. |
| **Font with the frame** | *Keep the book's font* (default), Cormorant Garamond (included), or any installed font. |
| **Italic text** | The text is set in italics; emphasised words turn upright so they still stand out. Off by default. |
| **Check for updates** | Looks for a newer Page Frame on GitHub. If there is one, it asks, then downloads, checks and installs it, and offers to restart KOReader. Shows your version. |
| **Check for updates automatically** | Once a day, when a book opens and Wi-Fi is already on, checks in the background and asks before installing. It never turns Wi-Fi on. On by default. |

**Keep text inside the frame**, **Font with the frame** and **Italic text** are greyed out for PDF, CBZ and DjVu, which have fixed layouts; the frame
itself still shows on them.

You can also bind **Toggle page frame** to a gesture (Settings → Taps and gestures → Gesture
manager), which flips **Show page frame**.

## Add your frames

Put image files in `koreader/frames/`, next to `koreader/plugins/`. Create the folder if it isn't
there. They appear in the menu by file name, so `Rose garland.webp` shows as "Rose garland".
Updates never touch this folder.

- **Formats:** PNG, JPG or WebP.
- **Portrait,** roughly the shape of your screen. The image is stretched to fill it.
- **A transparent or white background.** White is treated as paper. Anything darker becomes ink,
  so an image with a coloured background turns into a grey page.
- **Leave an empty middle.** The text goes in the largest rectangle without drawing. Tiny
  specks, like a stray dot in a scan, are ignored and erased where they would sit under the
  text. If the frame leaves less than 40% of the width or 30% of the
  height free, the margins are left alone.

## Install

1. Copy the `pageframe.koplugin` folder to `koreader/plugins/` on your device.
2. Restart KOReader.

Then add a frame (see above). The first frame in `koreader/frames/` is shown from the next book
you open. If you want the matching font, you don't need to install it: the plugin brings
Cormorant Garamond with it.

**Updating from 1.0 or 1.1:** 1.2.0 switches **Font with the frame** and **Italic text** off once,
so your KOReader font is used again, and sets margins to "yours, widened only if needed". Turn the
font options back on in the menu if you want them; that choice is kept.

**Updates:** after this first install, use **Check for updates** in the Page frame menu. Each
update is checked against its published SHA-256 before anything is replaced. The previous version
is kept as `koreader/plugins/pageframe.koplugin.old` until KOReader next starts. If an update was
ever interrupted halfway, rename that folder back to `pageframe.koplugin`.

**To remove it:**
1. Switch **Show page frame** off in any books it changed, so their margins go back.
2. Delete `koreader/plugins/pageframe.koplugin`, and `koreader/cache/pageframe/` if you like.

## Notes

- If your status bar's "Reclaim height" is on, the status bar sits on top of the frame's bottom
  edge. With it off (the default), the frame stops just above the status bar.
- **Fast book opens:** the first time a frame is drawn at a given screen size and setting, it's
  prepared (about a second and a half on a Paperwhite) and saved in `koreader/cache/pageframe/`.
  After that it loads from there almost instantly. It's prepared again by itself when you change
  the frame image, darkness or Crisp lines, or the screen size. The folder keeps the 6 most recent
  versions, and it's safe to delete at any time.
- In landscape the portrait frame is stretched to fit, so it looks a little squashed.
- Margins are fitted when a book opens, and again whenever you change the frame, change its
  darkness, rotate, or show or hide the status bar. If you change the margins by hand while a
  frame is on, yours are kept until one of those happens.

## Credits

- **Cormorant Garamond** by Christian Thalmann (Catharsis Fonts), under the SIL Open Font
  License 1.1. See `fonts/OFL.txt`.
