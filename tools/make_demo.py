#!/usr/bin/env python3
"""Builds a made-up demo library for Blossom's README screenshots.

Every title, author, description and quote here is invented, and the covers are
drawn below, so screenshots contain no real books or cover art.

    python3 tools/make_demo.py DEMO_DIR
    -> DEMO_DIR/books/*.epub (+ .sdr/ with cover.svg, notes) and DEMO_DIR/home (a KOReader home)
"""
import datetime, hashlib, os, random, shutil, sqlite3, sys, time, zipfile
from xml.sax.saxutils import escape

DEMO = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "demo")
BOOKS, HOME = os.path.join(DEMO, "books"), os.path.join(DEMO, "home")
PLUGIN = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "blossom.koplugin"))
random.seed(11)
D = datetime.date
today = D.today()

# stem, title, author, pages, pages read, reading stretches, cover style, description
LIBRARY = [
    ("fern-and-fable", "Fern & Fable", "Olive Ashby", 360, 360, [(D(2026, 1, 4), D(2026, 1, 22))], ("leaves", "#5a5a5a"),
     "Two rival botanists share one greenhouse and one very stubborn fern."),
    ("the-quiet-library", "The Quiet Library", "Hazel Moore", 280, 280, [(D(2026, 2, 6), D(2026, 2, 18))], ("stripes", "#8a8a8a"),
     "A librarian finds notes tucked into returned books, all in the same careful handwriting."),
    ("letters-to-the-sea", "Letters to the Sea", "Wren Holloway", 240, 240, [(D(2026, 3, 9), D(2026, 3, 19))], ("waves", "#6e6e6e"),
     "A lighthouse keeper writes to the ocean every night. One night, it writes back."),
    ("midnight-cardigan-club", "Midnight Cardigan Club", "Daisy Clarke", 500, 500, [(D(2026, 4, 11), D(2026, 5, 8))], ("dots", "#444444"),
     "Four friends, one knitting circle, and a mystery unravelling one stitch at a time."),
    ("paper-hearts-and-honey", "Paper Hearts & Honey", "Ivy Lane", 320, 320, [(D(2026, 6, 1), D(2026, 6, 15))], ("hearts", "#9a9a9a"),
     "A beekeeper and a bookbinder trade favours, then secrets, then something sweeter."),
    ("stardust-bakery", "Stardust Bakery", "Poppy Sinclair", 410, 410, [(D(2026, 7, 5), D(2026, 7, 26))], ("stars", "#3e3e3e"),
     "Every loaf at the little bakery comes with a wish — and some of them come true."),
    ("moonlight-at-willow-lane", "Moonlight at Willow Lane", "Clara Bell", 430, 430, [(D(2026, 8, 17), D(2026, 9, 10))], ("moon", "#2f2f2f"),
     "A quiet village, a moonlit garden, and a neighbour who only comes out at night."),
    ("the-teacup-society", "The Teacup Society", "June Marlowe", 380, 380, [(D(2026, 9, 1), D(2026, 9, 16))], ("teacups", "#b0b0b0"),
     "Seven strangers meet every Sunday for tea and end up rewriting each other's lives."),
    ("a-garden-of-small-hours", "A Garden of Small Hours", "Mina Hart", 380, 250, [(D(2026, 9, 17), today)], ("flowers", "#7a7a7a"),
     "Nell inherits her grandmother's overgrown garden, along with a notebook of letters "
     "never sent. As the roses come back, so do the people who once loved them."),
    ("the-lavender-letters", "The Lavender Letters", "Rosalie Finch", 320, 120, [(D(2026, 9, 12), D(2026, 9, 28))], ("lavender", "#a4a4a4"),
     "A bundle of lavender-scented letters leads a young archivist across three summers."),
    ("where-the-peonies-grow", "Where the Peonies Grow", "Elodie Rain", 900, 180, [(D(2026, 9, 24), D(2026, 9, 29))], ("peonies", "#565656"),
     "An epic, sweeping story of a family of florists across four generations."),
]

QUOTES = {
    "a-garden-of-small-hours": [
        ("21:04:12", "lighten", "Some flowers only open for the people who wait for them.", "this one ♡", 231, "Chapter 18"),
        ("21:32:40", "lighten", "She tucked the letter back into the book, as if the words might need somewhere soft to sleep.", "", 238, "Chapter 19"),
        ("21:40:02", None, "in Chapter 19", "", 240, "Chapter 19"),
    ],
    "where-the-peonies-grow": [
        ("07:15:30", "underscore", "Every bloom is a small, brave decision to begin again.", "", 176, "Part One"),
    ],
}


# Covers ------------------------------------------------------------------------

def pattern(kind, ink):
    """A soft grayscale motif scattered over the cover."""
    out = []
    for i in range(9):
        for j in range(6):
            x, y = 30 + j * 60 + (30 if i % 2 else 0), 40 + i * 62
            if kind == "dots":
                out.append(f'<circle cx="{x}" cy="{y}" r="6" fill="{ink}" opacity="0.25"/>')
            elif kind == "hearts":
                out.append(f'<path d="M{x} {y+8} C{x-14} {y-2} {x-8} {y-14} {x} {y-6} C{x+8} {y-14} {x+14} {y-2} {x} {y+8} Z" fill="{ink}" opacity="0.25"/>')
            elif kind == "stars":
                out.append(f'<path d="M{x} {y-9} L{x+3} {y-2} L{x+10} {y-2} L{x+4} {y+3} L{x+6} {y+10} L{x} {y+6} L{x-6} {y+10} L{x-4} {y+3} L{x-10} {y-2} L{x-3} {y-2} Z" fill="white" opacity="0.5"/>')
            elif kind in ("flowers", "peonies", "lavender"):
                r = 7 if kind == "flowers" else 10 if kind == "peonies" else 4
                for k in range(5 if kind != "lavender" else 3):
                    dy = -k * 7 if kind == "lavender" else 0
                    if kind == "lavender":
                        out.append(f'<ellipse cx="{x}" cy="{y+dy}" rx="4" ry="6" fill="{ink}" opacity="0.35"/>')
                    else:
                        a = 72 * k
                        out.append(f'<circle cx="{x}" cy="{y-r}" r="{r*0.7:.0f}" transform="rotate({a} {x} {y})" fill="white" opacity="0.55"/>')
            elif kind == "teacups":
                out.append(f'<path d="M{x-10} {y-6} L{x+10} {y-6} L{x+7} {y+6} L{x-7} {y+6} Z" fill="{ink}" opacity="0.25"/>'
                           f'<circle cx="{x+12}" cy="{y-1}" r="4" fill="none" stroke="{ink}" stroke-width="2" opacity="0.25"/>')
    if kind == "stripes":
        out = [f'<rect x="{k*40}" y="0" width="20" height="600" fill="{ink}" opacity="0.12"/>' for k in range(10)]
    if kind == "waves":
        out = [f'<path d="M0 {60+k*50} Q50 {40+k*50} 100 {60+k*50} T200 {60+k*50} T300 {60+k*50} T400 {60+k*50}" '
               f'fill="none" stroke="white" stroke-width="5" opacity="0.4"/>' for k in range(12)]
    if kind == "leaves":
        out = [f'<path d="M{30+j*70} {50+i*80} C{50+j*70} {20+i*80} {80+j*70} {40+i*80} {90+j*70} {70+i*80} '
               f'C{60+j*70} {80+i*80} {40+j*70} {70+i*80} {30+j*70} {50+i*80} Z" fill="white" opacity="0.35"/>'
               for i in range(8) for j in range(6)]
    if kind == "moon":
        out = [f'<circle cx="{random.randint(10, 390)}" cy="{random.randint(10, 590)}" r="{random.choice([1.5, 2, 3])}" fill="white" opacity="0.8"/>' for _ in range(70)]
        out.append('<circle cx="290" cy="140" r="60" fill="#f2f2f2"/><circle cx="315" cy="125" r="55" fill="#2f2f2f"/>')
    return "".join(out)


def cover_svg(title, author, style):
    kind, bg = style
    dark = int(bg[1:3], 16) < 0x80
    fg, soft = ("white", "#dddddd") if dark else ("#222222", "#444444")
    words, lines, line = title.split(), [], ""
    for w in words:
        if len(line) + len(w) > 13 and line:
            lines.append(line); line = w
        else:
            line = (line + " " + w).strip()
    lines.append(line)
    title_svg = "".join(
        f'<text x="200" y="{250 + i*58 - (len(lines)-1)*29}" font-family="Times" font-style="italic" font-weight="bold" '
        f'font-size="50" text-anchor="middle" fill="{fg}">{escape(l)}</text>' for i, l in enumerate(lines))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 600" width="400" height="600">'
            f'<rect width="400" height="600" fill="{bg}"/>{pattern(kind, "#222222" if not dark else "#ffffff")}'
            f'<rect x="30" y="150" width="340" height="230" rx="18" fill="{bg}" opacity="0.82"/>'
            f'{title_svg}'
            f'<text x="200" y="530" font-family="Times" font-size="28" letter-spacing="3" text-anchor="middle" fill="{soft}">{escape(author.upper())}</text>'
            f'</svg>')


# Books -----------------------------------------------------------------------------

def epub(path, title, author, description):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
        z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                   '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        z.writestr("content.opf", f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">'
                   f'<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{escape(title)}</dc:title><dc:creator>{escape(author)}</dc:creator>'
                   f'<dc:description>{escape(description)}</dc:description><dc:language>en</dc:language><dc:identifier id="id">{escape(title)}</dc:identifier></metadata>'
                   f'<manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>')
        z.writestr("c1.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{escape(title)}</title></head>'
                   f'<body><h1>{escape(title)}</h1><p>{escape(description)}</p>' + "<p>Once upon a time, in a very cozy corner of the world…</p>" * 40 + '</body></html>')


def partial_md5(path):
    m = hashlib.md5()
    with open(path, "rb") as f:
        for i in range(-1, 11):
            f.seek(0 if i < 0 else (1024 << (2 * i)) & 0xFFFFFFFF)
            d = f.read(1024)
            if not d:
                break
            m.update(d)
    return m.hexdigest()


def lua_str(s):
    return "[[" + s + "]]"


def main():
    shutil.rmtree(DEMO, ignore_errors=True)
    os.makedirs(BOOKS); os.makedirs(os.path.join(HOME, "settings")); os.makedirs(os.path.join(HOME, "plugins"))
    os.symlink(PLUGIN, os.path.join(HOME, "plugins", "blossom.koplugin"))

    db = sqlite3.connect(os.path.join(HOME, "settings", "statistics.sqlite3"))
    db.executescript("""
    CREATE TABLE book (id integer PRIMARY KEY autoincrement, title text, authors text, notes integer, last_open integer,
      highlights integer, pages integer, series text, language text, md5 text, total_read_time integer, total_read_pages integer);
    CREATE UNIQUE INDEX book_title_authors_md5 ON book(title, authors, md5);
    CREATE TABLE page_stat_data (id_book integer, page integer NOT NULL DEFAULT 0, start_time integer NOT NULL DEFAULT 0,
      duration integer NOT NULL DEFAULT 0, total_pages integer NOT NULL DEFAULT 0, UNIQUE (id_book, page, start_time));
    CREATE INDEX page_stat_data_start_time ON page_stat_data(start_time);
    CREATE TABLE numbers (number INTEGER PRIMARY KEY);
    WITH RECURSIVE counter AS (SELECT 1 as N UNION ALL SELECT N + 1 FROM counter WHERE N < 1000)
        INSERT INTO numbers SELECT N AS number FROM counter;
    CREATE VIEW page_stat AS
        SELECT id_book, first_page + idx - 1 AS page, start_time, duration / (last_page - first_page + 1) AS duration
        FROM (SELECT id_book, page, total_pages, pages, start_time, duration,
                ((page - 1) * pages) / total_pages + 1 AS first_page,
                max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page, idx
              FROM page_stat_data JOIN book ON book.id = id_book
              JOIN (SELECT number as idx FROM numbers) AS N ON idx <= (last_page - first_page + 1));
    PRAGMA user_version=20221111;
    """)
    hist = []
    for stem, title, author, pages, read, ranges, style, description in LIBRARY:
        path = os.path.join(BOOKS, stem + ".epub")
        epub(path, title, author, description)
        sdr = os.path.join(BOOKS, stem + ".sdr")
        os.makedirs(sdr)
        with open(os.path.join(sdr, "cover.svg"), "w") as f:
            f.write(cover_svg(title, author, style))
        db.execute("INSERT INTO book (title, authors, notes, last_open, highlights, pages, series, language, md5, total_read_time, total_read_pages) "
                   "VALUES (?,?,?,?,?,?,?,?,?,0,0)", (title, author, 0, 0, 0, pages, "", "en", partial_md5(path)))
        book_id = db.execute("SELECT last_insert_rowid()").fetchone()[0]
        days = []
        for start, end in ranges:
            d = start
            while d <= end:
                if random.random() < 0.85 or d >= D(2026, 9, 18):
                    days.append(d)
                d += datetime.timedelta(days=1)
        per_day = max(1, round(read / len(days)))
        page, total, last = 1, 0, 0
        for d in days:
            t = int(time.mktime(datetime.datetime(d.year, d.month, d.day, random.choice([7, 12, 20, 21, 22]), random.randint(0, 50)).timetuple()))
            for _ in range(per_day):
                if page > read:
                    break
                dur = random.randint(50, 110)
                db.execute("INSERT INTO page_stat_data VALUES (?,?,?,?,?)", (book_id, page, t, dur, pages))
                t += dur; total += dur; page += 1; last = t
        db.execute("UPDATE book SET total_read_time=?, total_read_pages=?, last_open=? WHERE id=?", (total, page - 1, last, book_id))
        hist.append((last, path))

        notes = []
        for t, drawer, text, note, pageno, chapter in QUOTES.get(stem, []):
            fields = [f'["datetime"] = {lua_str(today.isoformat() + " " + t)}', f'["text"] = {lua_str(text)}',
                      f'["pageno"] = {pageno}', f'["page"] = {pageno}', f'["chapter"] = {lua_str(chapter)}']
            if drawer:
                fields.append(f'["drawer"] = "{drawer}"')
            if note:
                fields.append(f'["note"] = {lua_str(note)}')
            notes.append("{ " + ", ".join(fields) + " }")
        with open(os.path.join(sdr, "metadata.epub.lua"), "w") as f:
            f.write("return {\n"
                    f'  ["doc_props"] = {{ ["title"] = {lua_str(title)}, ["authors"] = {lua_str(author)}, ["description"] = {lua_str(description)} }},\n'
                    '  ["annotations"] = {\n    ' + ",\n    ".join(notes) + "\n  },\n}\n")
    db.commit()

    hist.sort(reverse=True)
    with open(os.path.join(HOME, "history.lua"), "w") as f:
        f.write("return {\n" + "".join(f'    [{i+1}] = {{ ["time"] = {t}, ["file"] = [[{p}]] }},\n' for i, (t, p) in enumerate(hist)) + "}\n")
    with open(os.path.join(HOME, "settings.reader.lua"), "w") as f:
        f.write("return {\n"
                f'  ["home_dir"] = [[{BOOKS}]],\n  ["lastdir"] = [[{BOOKS}]],\n'
                '  ["quickstart_shown_version"] = 999999999999999,\n  ["start_with"] = "filemanager",\n  ["color_rendering"] = false,\n'
                f'  ["extra_plugin_paths"] = {{ [[{os.path.join(HOME, "plugins")}/]] }},\n'
                '  ["blossom"] = { ["yearly_goal"] = 12 },\n}\n')
    print("demo library ready:", DEMO)


if __name__ == "__main__":
    main()
