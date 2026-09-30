# 🌸 Blossom: a cute reading diary for KOReader

**Your reading statistics, but make it a garden.** Blossom turns the numbers KOReader already
collects into a soft little reading diary: streaks, weekly blooms, a shelf of covers, a month
calendar, a yearly goal and all your highlights, drawn in gentle grays for e-ink.

<p align="center">
  <img src="docs/screenshots/1-overview.png" width="260" alt="My reading garden">
  <img src="docs/screenshots/3-books.png" width="260" alt="My books">
  <img src="docs/screenshots/7-detail.png" width="260" alt="Book details">
</p>

<sub>Screenshots use a made-up demo library: every title, author, cover and quote is invented.</sub>

---

## 🌷 What's inside

Blossom opens as a full-screen diary with five pages. Swipe left or right, or use the page-turn
buttons, to move between them. The dots at the bottom show where you are, and a little sprout
marks the current page.

### My reading garden

<img src="docs/screenshots/1-overview.png" width="300" align="right" alt="My reading garden">

- A greeting for the time of day, between two sprouts, with a daily affirmation.
- **Eight numbers, each growing its own drawn flower:** books loved 🌷, hours of stories 🌼,
  pages turned 🌱, day streak 🌹, read today, this week 🌻, highlights 🦋 and bookmarks 🐞.
- Your longest streak, and a little flower bed along the bottom.
- **Tap any number** to open its own page:
  - **Books loved, hours of stories, pages turned, day streak, read today, this week:** a cover gallery,
    8 books per page, sorted to match (most recent, most time, most pages …).
  - **Highlights:** every highlight as a quote, with the book, page, date and your ✎ note.
  - **Bookmarks:** your bookmarks and highlights together, newest first, like KOReader's own bookmarks list.

<br clear="right">

<p align="center">
  <img src="docs/screenshots/9-garden-books.png" width="260" alt="Hours of stories gallery">
  <img src="docs/screenshots/10-garden-highlights.png" width="260" alt="My highlights">
  <img src="docs/screenshots/11-garden-bookmarks.png" width="260" alt="My bookmarks">
</p>

### This week

<img src="docs/screenshots/2-week.png" width="300" align="right" alt="This week">

- Minutes read on each of the last 7 days, with a ♥ over your best day.
- Your total for the week and your best day.
- **Books that kept me company:** just the covers of what you read this week.

<br clear="right">

### My books

<img src="docs/screenshots/3-books.png" width="300" align="right" alt="My books">

- Every book you've read, most recent first, 8 per page (4×2).
- Each cover sits edge to edge in a rounded frame, with its title, **% read** and **time spent** below.
- Finished books get a little 🎀 bow.

<br clear="right">

### This month

<p>
  <img src="docs/screenshots/4-month-covers.png" width="300" alt="This month, covers">
  <img src="docs/screenshots/5-month-calendar.png" width="300" alt="This month, calendar">
</p>

- Switch views with the icons beside the month: **▦ calendar** and a 🌹 **rose for covers**.
- **Covers:** the books you read that month, as a gallery.
- **Calendar:** Sunday-first and shaded by how long you read each day.
  - **Book bars** (title · time) stretch across the days you kept reading a book.
  - When books overlap, their bars stack.
- ‹ › take you back through earlier months.
- **Tap a day** to open that day's page.

### My year

<img src="docs/screenshots/6-year.png" width="300" align="right" alt="My year">

- Your **yearly reading goal** (books finished): a wavy line with a heart riding along it.
- A status line, for example "67% of my goal · right on track".
- Tap the little ✎ pencil to change your goal.
- Your year in numbers: time, pages and days.
- A **line chart** of reading by month, with a ♥ over your best month.

<br clear="right">

### Book details

<img src="docs/screenshots/7-detail.png" width="300" align="right" alt="Book details">

Tap any book, anywhere, to open it:

- **Top:** the cover, title, author, a short snippet of the book's description, a wavy progress
  line and "66% read · 250 of 380 pages".
- **My reading:** time together, reading days, pages per hour, time left, highlights and bookmarks.
- **My highlights:** your highlights from this book.

<br clear="right">

### A day

<img src="docs/screenshots/8-day.png" width="300" align="right" alt="A day">

Tap a day in the calendar to see:

- time read, pages, highlights and bookmarks for that day
- the covers of the books you read
- the highlights and bookmarks you made that day

<br clear="right">

### Getting around

- **Paging:** every gallery and list pages the same way: soft dots, a little sprout for the page
  you're on, and ‹ › either side. Long lists show a window of dots plus a small "12 / 40".
- **Close:** swipe down, press Back, or tap the little flower **×** at the top-left.
- **Go back:** pages you open from the dashboard have a flower **‹** in the same spot.

---

## 💕 Install

1. Download or copy the `blossom.koplugin` folder, including its `icons` folder.
2. Connect your e-reader by USB and copy the folder into KOReader's `plugins` folder
   (for example `koreader/plugins/` on Kindle and Kobo).
3. Restart KOReader.
4. Open **Tools (🔧) → ❀ Blossom reading diary**.

Tip: bind it to a gesture in **Settings → Taps and gestures → Gesture manager**
(action **General → Blossom reading diary**).

## 🎀 Good to know

- **Statistics:** Blossom reads the **Statistics** plugin's data, so keep that plugin enabled
  (it is by default). Blossom never changes your statistics.
- **What it saves:** only your yearly goal (`blossom.yearly_goal` in KOReader's settings, default 12).
- **Covers:** they come from the Cover Browser cache when available, otherwise from the book file.
  Books that were moved or deleted get a soft placeholder tile instead.
- **Highlights, bookmarks and snippets:** these come from each book's KOReader sidecar (`.sdr`).
  Only books in your reading history are read. If you open Blossom while reading, it saves the open
  book's notes first, so today's highlights show up.
- **Finished books:** a book counts as finished at 98% of its pages. For the yearly goal, it counts
  in the year you last read it.
- **Look:** everything is grayscale and drawn for e-ink. Page changes use a full refresh, so there's
  no ghosting.

---

## 🧁 Development

Tests run with plain LuaJIT from the repo root:

```bash
luajit tests/test_data.lua
```

```bash
luajit tests/test_plugin_load.lua
```

`test_plugin_load.lua` builds every page against stand-ins for KOReader's modules. To see the
real thing, `tools/screenshots.sh` builds the made-up demo library, runs the KOReader macOS
build with it and saves every page to `docs/screenshots/`:

```bash
tools/screenshots.sh ~/Applications/KOReader.app
```

| File | What it does |
|------|--------------|
| `main.lua` | Menu, gesture action and database queries |
| `blossom_data.lua` | Pure calculations: streaks, weeks, months, calendar, goal, spans, snippets |
| `blossom_view.lua` | The five dashboard pages |
| `blossom_detail.lua` | Book details |
| `blossom_day.lua` | A day's books, highlights and bookmarks |
| `blossom_more.lua` | The garden's gallery and list pages |
| `blossom_covers.lua` | Matches statistics entries to book files and covers |
| `blossom_theme.lua` | Grays, fonts, header, wavy line, quotes and other shared pieces |
| `icons/` | The drawn bow, heart, pencil, close and back flowers, and garden flowers |
| `tools/make_garden_icons.py` | Redraws the flower icons |
| `tools/make_demo.py` | Builds the demo library (fictional books, drawn covers) |
| `tools/screenshots.sh` | Rebuilds `docs/screenshots/` in the KOReader macOS build |
