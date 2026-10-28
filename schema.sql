-- library.db schema
-- Run with: sqlite3 library.db < schema.sql   (or via build_library.py)
-- Foreign keys are enforced per connection in SQLite, so run
-- `PRAGMA foreign_keys = ON;` whenever you open the database.

PRAGMA foreign_keys = ON;

------------------------------------------------------------------------
-- Table 1: Books (what the library owns)
------------------------------------------------------------------------
CREATE TABLE books (
    book_id        INTEGER PRIMARY KEY,
    title          TEXT    NOT NULL,
    author_1       TEXT    NOT NULL,
    author_2       TEXT,
    author_3       TEXT,
    isbn           TEXT    UNIQUE,      -- ISBN-13 barcode, digits only, kept as TEXT
    isbn10         TEXT    UNIQUE,      -- older 10-character ISBN, leading zeros kept
    publisher      TEXT,
    year_published INTEGER,
    genre          TEXT,
    call_number    TEXT,                -- where it sits on the shelf
    total_copies   INTEGER NOT NULL DEFAULT 1,

    CHECK (author_2 IS NOT NULL OR author_3 IS NULL),           -- fill authors in order
    CHECK (isbn   IS NULL OR (length(isbn) = 13 AND isbn NOT GLOB '*[^0-9]*')),
    CHECK (isbn10 IS NULL OR (length(isbn10) = 10 AND isbn10 GLOB '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9X]')),
    CHECK (year_published IS NULL OR typeof(year_published) = 'integer'),  -- whole years only
    CHECK (typeof(total_copies) = 'integer' AND total_copies >= 0)
);

CREATE INDEX idx_books_title    ON books (title    COLLATE NOCASE);
CREATE INDEX idx_books_author_1 ON books (author_1 COLLATE NOCASE);
CREATE INDEX idx_books_author_2 ON books (author_2 COLLATE NOCASE);
CREATE INDEX idx_books_author_3 ON books (author_3 COLLATE NOCASE);

------------------------------------------------------------------------
-- Table 2: Members (who can borrow)
------------------------------------------------------------------------
CREATE TABLE members (
    member_id    INTEGER PRIMARY KEY,
    first_name   TEXT NOT NULL,
    last_name    TEXT NOT NULL,
    email        TEXT NOT NULL UNIQUE COLLATE NOCASE,   -- hold notices go by email
    phone        TEXT,
    address      TEXT,
    join_date    TEXT NOT NULL DEFAULT (date('now', 'localtime')),
    card_expires TEXT NOT NULL DEFAULT (date('now', 'localtime', '+1 year')),
    status       TEXT NOT NULL DEFAULT 'active',

    CHECK (email LIKE '_%@_%._%'),
    CHECK (join_date    IS date(join_date)),            -- must be YYYY-MM-DD
    CHECK (card_expires IS date(card_expires) AND card_expires > join_date),
    CHECK (status IN ('active', 'suspended', 'expired'))
);

------------------------------------------------------------------------
-- Table 3: Loans (who has what, and when)
------------------------------------------------------------------------
CREATE TABLE loans (
    loan_id       INTEGER PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books (book_id),
    member_id     INTEGER NOT NULL REFERENCES members (member_id),
    checkout_date TEXT    NOT NULL DEFAULT (date('now', 'localtime')),
    due_date      TEXT    NOT NULL DEFAULT (date('now', 'localtime', '+14 days')),
    return_date   TEXT,                                 -- blank until returned
    late_fee      REAL    NOT NULL DEFAULT 0.00,

    CHECK (checkout_date IS date(checkout_date)),
    CHECK (due_date IS date(due_date) AND due_date >= checkout_date),
    CHECK (return_date IS NULL OR (return_date IS date(return_date) AND return_date >= checkout_date)),
    CHECK (late_fee >= 0)
);

CREATE INDEX idx_loans_member ON loans (member_id);
CREATE INDEX idx_loans_open   ON loans (book_id, due_date) WHERE return_date IS NULL;

------------------------------------------------------------------------
-- Table 4: Holds (the waitlist)
--   status: waiting   -> in line
--           ready     -> a copy is set aside; must be picked up by pickup_by
--           picked_up -> member checked the held copy out
--           expired   -> missed pickup_by; the next person moves up
--           cancelled -> member left the line
------------------------------------------------------------------------
CREATE TABLE holds (
    hold_id       INTEGER PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books (book_id),
    member_id     INTEGER NOT NULL REFERENCES members (member_id),
    request_time  TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    status        TEXT    NOT NULL DEFAULT 'waiting',
    notified_time TEXT,                                 -- blank until notified (email sent)
    reminder_time TEXT,                                 -- blank until next-day reminder sent
    pickup_by     TEXT,

    CHECK (status IN ('waiting', 'ready', 'picked_up', 'expired', 'cancelled')),
    CHECK (datetime(request_time) IS NOT NULL),
    CHECK (notified_time IS NULL OR datetime(notified_time) IS NOT NULL),
    CHECK (reminder_time IS NULL OR datetime(reminder_time) IS NOT NULL),
    CHECK (pickup_by IS NULL OR pickup_by IS date(pickup_by)),
    CHECK (status <> 'ready' OR (notified_time IS NOT NULL AND pickup_by IS NOT NULL))
);

-- Rule 1: a member can't be in line twice for the same book at the same time.
CREATE UNIQUE INDEX uq_holds_one_active
    ON holds (book_id, member_id) WHERE status IN ('waiting', 'ready');

-- Rule 3: the line is ordered by request_time.
CREATE INDEX idx_holds_queue ON holds (book_id, status, request_time);

------------------------------------------------------------------------
-- Views
------------------------------------------------------------------------

-- Authors shown as "Author 1, Author 2, Author 3".
CREATE VIEW book_authors AS
SELECT book_id,
       author_1
         || coalesce(', ' || author_2, '')
         || coalesce(', ' || author_3, '') AS author
FROM books;

-- What a person searching sees (rules 3 and 5): a copy set aside for a
-- hold is NOT counted as available, even though it is on the shelf.
CREATE VIEW catalog AS
SELECT b.book_id,
       b.title,
       a.author,
       b.isbn,
       b.isbn10,
       b.year_published,
       b.call_number,
       b.total_copies,
       coalesce(l.on_loan, 0)                                       AS copies_on_loan,
       coalesce(h.on_hold_shelf, 0)                                 AS copies_held_for_members,
       max(b.total_copies - coalesce(l.on_loan, 0) - coalesce(h.on_hold_shelf, 0), 0)
                                                                    AS copies_available,
       CASE
           WHEN b.total_copies - coalesce(l.on_loan, 0) - coalesce(h.on_hold_shelf, 0) > 0
               THEN 'Available'
           WHEN coalesce(h.on_hold_shelf, 0) > 0 AND coalesce(l.on_loan, 0) < b.total_copies
               THEN 'On hold for another member'
           ELSE 'Checked out'
       END                                                          AS availability,
       CASE
           WHEN b.total_copies - coalesce(l.on_loan, 0) - coalesce(h.on_hold_shelf, 0) > 0
               THEN NULL
           ELSE l.next_due
       END                                                          AS expected_back,
       coalesce(w.in_line, 0)                                       AS waitlist_length
FROM books b
JOIN book_authors a USING (book_id)
LEFT JOIN (SELECT book_id, count(*) AS on_loan, min(due_date) AS next_due
           FROM loans WHERE return_date IS NULL GROUP BY book_id) l USING (book_id)
LEFT JOIN (SELECT book_id, count(*) AS on_hold_shelf
           FROM holds WHERE status = 'ready' GROUP BY book_id) h USING (book_id)
LEFT JOIN (SELECT book_id, count(*) AS in_line
           FROM holds WHERE status = 'waiting' GROUP BY book_id) w USING (book_id);

-- The waitlist in order, with each member's place in line.
CREATE VIEW waitlist AS
SELECT h.hold_id,
       h.book_id,
       b.title,
       h.member_id,
       m.first_name || ' ' || m.last_name AS member_name,
       h.request_time,
       row_number() OVER (PARTITION BY h.book_id ORDER BY h.request_time, h.hold_id) AS place_in_line
FROM holds h
JOIN books b   USING (book_id)
JOIN members m USING (member_id)
WHERE h.status = 'waiting';

-- Rule 6: holds waiting on the pickup shelf, with who to email and
-- whether the next-day reminder is due.
CREATE VIEW hold_notifications AS
SELECT h.hold_id,
       m.first_name || ' ' || m.last_name AS member_name,
       m.email,
       b.title,
       h.notified_time,
       h.pickup_by,
       CASE
           WHEN h.reminder_time IS NULL
                AND date('now', 'localtime') >= date(h.notified_time, '+1 day')
               THEN 1 ELSE 0
       END AS reminder_due
FROM holds h
JOIN members m USING (member_id)
JOIN books b   USING (book_id)
WHERE h.status = 'ready';

------------------------------------------------------------------------
-- Triggers (the waitlist rules)
------------------------------------------------------------------------

-- Rules 1 and 2 (plus: only active members, and only for books that are out).
CREATE TRIGGER holds_before_insert
BEFORE INSERT ON holds
BEGIN
    SELECT RAISE(ABORT, 'Member is not active')
    WHERE (SELECT status FROM members WHERE member_id = NEW.member_id) IS NOT 'active';

    SELECT RAISE(ABORT, 'Member is already in line for this book')
    WHERE EXISTS (SELECT 1 FROM holds
                  WHERE book_id = NEW.book_id AND member_id = NEW.member_id
                    AND status IN ('waiting', 'ready'));

    SELECT RAISE(ABORT, 'Member already has this book checked out')
    WHERE EXISTS (SELECT 1 FROM loans
                  WHERE book_id = NEW.book_id AND member_id = NEW.member_id
                    AND return_date IS NULL);

    SELECT RAISE(ABORT, 'A copy is available - check it out instead of placing a hold')
    WHERE (SELECT copies_available FROM catalog WHERE book_id = NEW.book_id) > 0;
END;

-- Rule 3 and 6: when a copy comes back, the earliest waiting hold becomes
-- 'ready', is stamped as notified, and gets 2 days to pick it up.
CREATE TRIGGER loans_after_return
AFTER UPDATE OF return_date ON loans
WHEN OLD.return_date IS NULL AND NEW.return_date IS NOT NULL
BEGIN
    UPDATE holds
    SET status        = 'ready',
        notified_time = datetime('now', 'localtime'),
        pickup_by     = date('now', 'localtime', '+2 days')
    WHERE hold_id = (SELECT hold_id FROM holds
                     WHERE book_id = NEW.book_id AND status = 'waiting'
                     ORDER BY request_time, hold_id
                     LIMIT 1);
END;

-- Rule 4: if a ready hold expires (or is cancelled), the next person moves up.
CREATE TRIGGER holds_after_release
AFTER UPDATE OF status ON holds
WHEN OLD.status = 'ready' AND NEW.status IN ('expired', 'cancelled')
BEGIN
    UPDATE holds
    SET status        = 'ready',
        notified_time = datetime('now', 'localtime'),
        pickup_by     = date('now', 'localtime', '+2 days')
    WHERE hold_id = (SELECT hold_id FROM holds
                     WHERE book_id = NEW.book_id AND status = 'waiting'
                     ORDER BY request_time, hold_id
                     LIMIT 1);
END;

-- Rule 5 at the desk: a copy set aside for someone can't be checked out by
-- anyone else. Also only active members can borrow.
CREATE TRIGGER loans_before_insert
BEFORE INSERT ON loans
BEGIN
    SELECT RAISE(ABORT, 'Member is not active')
    WHERE (SELECT status FROM members WHERE member_id = NEW.member_id) IS NOT 'active';

    SELECT RAISE(ABORT, 'No copy available for this member')
    WHERE (SELECT total_copies FROM books WHERE book_id = NEW.book_id)
        - (SELECT count(*) FROM loans WHERE book_id = NEW.book_id AND return_date IS NULL)
        - (SELECT count(*) FROM holds WHERE book_id = NEW.book_id AND status = 'ready'
                                        AND member_id <> NEW.member_id)
        <= 0;
END;

-- Checking out the book closes that member's place in line.
CREATE TRIGGER loans_after_insert
AFTER INSERT ON loans
BEGIN
    UPDATE holds
    SET status = 'picked_up'
    WHERE book_id = NEW.book_id AND member_id = NEW.member_id
      AND status IN ('waiting', 'ready');
END;
