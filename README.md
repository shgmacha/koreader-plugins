# ✿ Blossom — a cute reading diary for KOReader

**Your reading statistics, but make it pretty.** Blossom turns the numbers KOReader already
collects into a soft little diary: streaks, weekly blooms, book progress ribbons and a
monthly shelf of covers. Designed for grayscale e-ink.

```
        ˚ ✿ Blossom ✿ ˚
       My reading garden
        · ♡ · ✿ · ♡ ·

   Good evening, darling ♡
 ╭────────────╮ ╭────────────╮
 │ ✿ 12       │ │ ♡ 51h 20m  │
 │ books loved│ │ of stories │
 ╰────────────╯ ╰────────────╯
        ‹   ♥   ♡   ♡   ♡   ›
```

## 🌸 What's inside

Swipe left / right (or use the page-turn buttons) between four pages:

| Page | What you see |
|------|--------------|
| **My reading garden** | A greeting, books loved, total reading time, pages turned, your day streak ♥, today, this week, your longest streak and a little affirmation |
| **This week** | A bar chart of the last 7 days (♥ over your best day), a 14-day flower row (✿ = you read that day) and the covers of the **books that kept you company** this week |
| **My books** | Your 6 most recent books with a progress ribbon, time spent and a ♥ when finished |
| **This month** | Month totals and a grid of **book covers** you read that month; use ‹ › to look back at earlier months |

Swipe **down** or tap **✕** to close.

## 💕 Install

1. Download or copy the `blossom.koplugin` folder.
2. Connect your e-reader by USB and copy it into KOReader's `plugins` folder
   (for example `koreader/plugins/` on Kindle and Kobo).
3. Restart KOReader.
4. Open **Tools (🔧) → ✿ Blossom reading diary**.

Tip: bind it to a gesture in **Settings → Taps and gestures → Gesture manager**
(action **General → Blossom reading diary**).

## 🎀 Good to know

- Blossom reads the **Statistics** plugin's data, so keep that plugin enabled
  (it is by default). Blossom never changes your statistics.
- **Covers** come from the Cover Browser cache when available, otherwise they're read
  from the book file. Books that were moved or deleted get a pretty placeholder tile instead.
- A book counts as finished at 98% of its pages.

## 🧁 Development

Tests run with plain LuaJIT from the repo root:

```bash
luajit tests/test_data.lua
```

```bash
luajit tests/test_plugin_load.lua
```

- `blossom_data.lua` — pure calculations (streaks, weeks, months, formatting)
- `blossom_view.lua` — the dashboard pages
- `blossom_covers.lua` — matches statistics entries to book files and covers
- `blossom_theme.lua` — grays, fonts and decorations
- `main.lua` — menu, gesture action and database queries
