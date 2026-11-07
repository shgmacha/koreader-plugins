# Page Frame

A decorative frame around the page while you read, for KOReader.

- **Bring your own frame:** put a frame image in `koreader/frames/` and it is drawn on every
  page. No frame image comes with the plugin; see [Add your frames](#add-your-frames).
- The frame is drawn on every page in soft grey ink, and it works on greyscale Kindles and in
  night mode.
- In EPUB-style books, the text is kept clear of the drawing. The plugin sets the book's margins
  to the largest space the frame leaves free, and puts your margins back when you turn the frame
  off.
- It comes with a matching font, **Cormorant Garamond Italic**, which you can change or turn off.
  Your book's own font setting is never touched.

## The menu

Open the reader menu, go to the **typeset** tab (the "A" icon), then **Page frame**.

| Item | What it does |
|---|---|
| **None** / your frames | Which frame to show. The choice applies to every book. Until you pick one, the first frame (by name) is used. With no frames installed, a hint says where to put them. |
| **Darkness** | Soft (default), Normal or Bold ink. |
| **Crisp lines** | Sharpens the frame's lines and deepens its shading, so soft artwork looks crisp on e-ink. On by default; turn it off for frames that are already clean line art. |
| **Keep text inside the frame** | Sets the margins so the text never touches the drawing. On by default. |
| **Font with the frame** | Cormorant Garamond (included), any installed font, or *Keep the book's font*. |
| **Italic text** | The text is set in italics; emphasised words turn upright so they still stand out. On by default. |
| **Check for updates** | Looks for a newer Page Frame on GitHub. If there is one, it asks, then downloads, checks and installs it, and offers to restart KOReader. Shows your version. |
| **Check for updates automatically** | Once a day, when a book opens and Wi-Fi is already on, checks in the background and asks before installing. It never turns Wi-Fi on. On by default. |

**Keep text inside the frame**, **Font with the frame** and **Italic text** are greyed out for PDF, CBZ and DjVu, which have fixed layouts; the frame
itself still shows on them.

You can also bind **Toggle page frame** to a gesture (Settings → Taps and gestures → Gesture
manager), which switches between no frame and the last one you used.

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
you open. You don't need to install any fonts: the plugin loads Cormorant Garamond itself.

**Updates:** after this first install, use **Check for updates** in the Page frame menu. Each
update is checked against its published SHA-256 before anything is replaced. The previous version
is kept as `koreader/plugins/pageframe.koplugin.old` until KOReader next starts. If an update was
ever interrupted halfway, rename that folder back to `pageframe.koplugin`.

**To remove it:**
1. Set the frame to **None** in any books it changed, so their margins go back.
2. Delete `koreader/plugins/pageframe.koplugin`.

## Notes

- If your status bar's "Reclaim height" is on, the status bar sits on top of the frame's bottom
  edge. With it off (the default), the frame stops just above the status bar.
- In landscape the portrait frame is stretched to fit, so it looks a little squashed.
- Margins are fitted when a book opens, and again whenever you change the frame, change its
  darkness, rotate, or show or hide the status bar. If you change the margins by hand while a
  frame is on, yours are kept until one of those happens.

## Credits

- **Cormorant Garamond** by Christian Thalmann (Catharsis Fonts), under the SIL Open Font
  License 1.1. See `fonts/OFL.txt`.
