"""Build library.db from schema.sql and books.csv.

Usage:  python3 build_library.py           (refuses to overwrite an existing library.db)
        python3 build_library.py --force   (rebuilds from scratch; erases members/loans/holds)
"""

import csv
import re
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DB_PATH = HERE / "library.db"
SCHEMA_PATH = HERE / "schema.sql"
CSV_PATH = HERE / "books.csv"

MAX_AUTHORS = 3
NAME_SUFFIXES = {"jr", "jr.", "sr", "sr.", "ii", "iii", "iv"}


def clean_text(value):
    """Trim and collapse runs of whitespace; empty becomes None."""
    value = re.sub(r"\s+", " ", value or "").strip()
    return value or None


def isbn13_check_digit(first12):
    total = sum(int(d) * (1 if i % 2 == 0 else 3) for i, d in enumerate(first12))
    return str((10 - total % 10) % 10)


def clean_isbn10(raw):
    """Restore leading zeros lost when the CSV stored ISBNs as numbers."""
    raw = (raw or "").strip().upper()
    if not raw:
        return None
    isbn10 = raw.zfill(10)
    return isbn10 if re.fullmatch(r"\d{9}[\dX]", isbn10) else None


def isbn13_from_isbn10(isbn10):
    first12 = "978" + isbn10[:9]
    return first12 + isbn13_check_digit(first12)


def isbn13_from_scientific(raw):
    """Recover an ISBN-13 from a value like '9.78067172365e+12'.

    Spreadsheet export rounded it to 12 significant digits, so the true number
    is within +/-5 of the rounded one. Exactly one number in that window
    usually has a valid check digit; if none or several do, give up.
    """
    try:
        rounded = round(float(raw))
    except ValueError:
        return None
    matches = []
    for n in range(rounded - 5, rounded + 5):
        digits = str(n)
        if (len(digits) == 13 and digits[:3] in ("978", "979")
                and isbn13_check_digit(digits[:12]) == digits[12]):
            matches.append(digits)
    return matches[0] if len(matches) == 1 else None


def split_authors(raw):
    authors = [clean_text(a) for a in (raw or "").split(",")]
    return [a for a in authors if a]


def call_number(author):
    """Shelf code from the first author's last name, e.g. 'Mary Shelley' -> 'SHE'."""
    words = [w for w in author.split() if w.lower() not in NAME_SUFFIXES]
    letters = re.sub(r"[^\w]", "", words[-1] if words else author).replace("_", "")
    return letters[:3].upper() or None


def whole_year(raw):
    raw = (raw or "").strip()
    return int(float(raw)) if raw else None


def load_books(conn):
    stats = {"rows": 0, "isbn_from_isbn10": 0, "isbn_recovered": 0, "no_isbn": 0,
             "authors_trimmed": 0}
    seen_isbns = set()
    rows = []

    with CSV_PATH.open(encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            authors = split_authors(r["authors"])
            if len(authors) > MAX_AUTHORS:
                stats["authors_trimmed"] += 1
            authors = (authors + [None, None, None])[:MAX_AUTHORS]

            isbn10 = clean_isbn10(r["isbn"])
            if isbn10:
                isbn = isbn13_from_isbn10(isbn10)
                stats["isbn_from_isbn10"] += 1
            else:
                isbn = isbn13_from_scientific(r["isbn13"]) if r["isbn13"].strip() else None
                if isbn:
                    stats["isbn_recovered"] += 1
            if isbn in seen_isbns:
                isbn = None
            if isbn:
                seen_isbns.add(isbn)
            else:
                stats["no_isbn"] += 1

            rows.append((
                int(r["book_id"]),
                clean_text(r["title"]),
                authors[0], authors[1], authors[2],
                isbn,
                isbn10,
                None,                       # publisher: not in books.csv
                whole_year(r["original_publication_year"]),
                None,                       # genre: not in books.csv
                call_number(authors[0]),
                1,                          # total_copies: one copy of each to start
            ))
            stats["rows"] += 1

    conn.executemany(
        """INSERT INTO books (book_id, title, author_1, author_2, author_3, isbn, isbn10,
                              publisher, year_published, genre, call_number, total_copies)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        rows,
    )
    return stats


def main():
    if DB_PATH.exists():
        if "--force" not in sys.argv:
            sys.exit(f"{DB_PATH.name} already exists. Use --force to rebuild it from scratch.")
        DB_PATH.unlink()

    conn = sqlite3.connect(DB_PATH)
    try:
        conn.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
        with conn:
            stats = load_books(conn)
    finally:
        conn.close()

    print(f"Created {DB_PATH.name} with {stats['rows']} books")
    print(f"  ISBN-13 rebuilt from ISBN-10:          {stats['isbn_from_isbn10']}")
    print(f"  ISBN-13 recovered from rounded value:  {stats['isbn_recovered']}")
    print(f"  No usable ISBN:                        {stats['no_isbn']}")
    print(f"  Books with >{MAX_AUTHORS} authors (kept first {MAX_AUTHORS}): {stats['authors_trimmed']}")


if __name__ == "__main__":
    main()
