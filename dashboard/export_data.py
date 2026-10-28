"""Export library.db to dashboard/library-data.json for the Forte Library app.

Usage:  python3 dashboard/export_data.py
"""

import json
import sqlite3
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
DB_PATH = HERE.parent / "library.db"
OUT_PATH = HERE / "library-data.json"


def rows(conn, sql):
    return [list(r) for r in conn.execute(sql)]


def main():
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    data = {
        "asOf": date.today().isoformat(),
        # Compact rows; column order is listed beside each so the page can name them.
        "bookColumns": ["id", "title", "author", "isbn", "isbn10", "year", "call", "copies"],
        "books": rows(conn, """
            SELECT b.book_id, b.title, a.author, b.isbn, b.isbn10,
                   b.year_published, b.call_number, b.total_copies
            FROM books b JOIN book_authors a USING (book_id)
            ORDER BY b.book_id"""),
        "memberColumns": ["id", "first", "last", "email", "status", "joined", "expires"],
        "members": rows(conn, """
            SELECT member_id, first_name, last_name, email, status, join_date, card_expires
            FROM members ORDER BY member_id"""),
        "loanColumns": ["id", "book", "member", "checkout", "due", "returned", "fee"],
        "loans": rows(conn, """
            SELECT loan_id, book_id, member_id, checkout_date, due_date, return_date, late_fee
            FROM loans ORDER BY loan_id"""),
        "holdColumns": ["id", "book", "member", "requested", "status", "notified", "reminded", "pickupBy"],
        "holds": rows(conn, """
            SELECT hold_id, book_id, member_id, request_time, status,
                   notified_time, reminder_time, pickup_by
            FROM holds ORDER BY hold_id"""),
    }
    conn.close()

    OUT_PATH.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {OUT_PATH.name}: {len(data['books'])} books, {len(data['members'])} members, "
          f"{len(data['loans'])} loans, {len(data['holds'])} holds "
          f"({OUT_PATH.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
