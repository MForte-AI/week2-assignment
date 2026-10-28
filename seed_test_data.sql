-- Test members, loans and holds for books 1-10, so the catalog shows every status.
-- Run once:  sqlite3 library.db < seed_test_data.sql
-- Steps go through the normal triggers (checkout -> hold -> return), so the
-- waitlist rules decide who becomes 'ready'. Fails without changes if run twice.

.bail on
PRAGMA foreign_keys = ON;
BEGIN;

INSERT INTO members (member_id, first_name, last_name, email, phone, address, join_date, card_expires, status) VALUES
    (207, 'Ada',       'Lovelace', 'ada@example.com',       '615-555-0142', '12 Main St, Nashville TN',     '2026-09-01', '2027-09-01', 'active'),
    (208, 'Alan',      'Turing',   'alan@example.com',      '615-555-0143', '48 Church St, Nashville TN',   '2026-09-03', '2027-09-03', 'active'),
    (209, 'Grace',     'Hopper',   'grace@example.com',     '615-555-0144', '7 Broadway, Nashville TN',     '2026-09-05', '2027-09-05', 'active'),
    (210, 'Katherine', 'Johnson',  'katherine@example.com', '615-555-0145', '301 Elm St, Franklin TN',      '2026-09-10', '2027-09-10', 'active'),
    (211, 'Claude',    'Shannon',  'claude@example.com',    '615-555-0146', '22 Oak Ave, Brentwood TN',     '2026-09-12', '2027-09-12', 'active'),
    (212, 'Hedy',      'Lamarr',   'hedy@example.com',      '615-555-0147', '9 Music Row, Nashville TN',    '2026-09-15', '2027-09-15', 'active'),
    (213, 'John',      'Neumann',  'john@example.com',      '615-555-0148', '150 West End, Nashville TN',   '2026-09-20', '2027-09-20', 'active'),
    (214, 'Annie',     'Easley',   'annie@example.com',     '615-555-0149', '63 Belmont Blvd, Nashville TN','2026-09-25', '2027-09-25', 'active'),
    (215, 'Charles',   'Babbage',  'charles@example.com',   '615-555-0150', '5 Hillsboro Rd, Franklin TN',  '2026-09-02', '2027-09-02', 'suspended');

-- More than one copy of a few books, so counts can be mixed.
UPDATE books SET total_copies = 3 WHERE book_id = 1;   -- The Hunger Games
UPDATE books SET total_copies = 2 WHERE book_id = 2;   -- Harry Potter and the Sorcerer's Stone
UPDATE books SET total_copies = 2 WHERE book_id = 7;   -- The Hobbit

-- Book 1: 2 of 3 copies out -> Available (1 left)
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5531, 1, 207, '2026-10-20', '2026-11-03'),
    (5532, 1, 208, '2026-10-22', '2026-11-05');

-- Book 2: both copies out, 2 people in line -> Checked out
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5533, 2, 209, '2026-10-14', '2026-10-28'),
    (5534, 2, 210, '2026-10-21', '2026-11-04');
INSERT INTO holds (hold_id, book_id, member_id, request_time) VALUES
    (88, 2, 211, '2026-10-22 09:15'),
    (89, 2, 212, '2026-10-23 16:40');

-- Book 3: returned, set aside for the first in line, 1 still waiting -> On hold
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5535, 3, 213, '2026-10-10', '2026-10-24');
INSERT INTO holds (hold_id, book_id, member_id, request_time) VALUES
    (90, 3, 207, '2026-10-12 10:05'),
    (91, 3, 208, '2026-10-15 18:20');
UPDATE loans SET return_date = '2026-10-27', late_fee = 0.75 WHERE loan_id = 5535;   -- hold 90 -> ready
UPDATE holds SET notified_time = '2026-10-27 14:00:00', pickup_by = '2026-10-29'    -- told yesterday: reminder due
WHERE hold_id = 90;

-- Book 4: overdue, 1 person in line -> Checked out
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5536, 4, 211, '2026-10-01', '2026-10-15');
INSERT INTO holds (hold_id, book_id, member_id, request_time) VALUES
    (92, 4, 209, '2026-10-10 12:00');

-- Book 5: borrowed and returned late (history only) -> Available
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5537, 5, 212, '2026-09-20', '2026-10-04');
UPDATE loans SET return_date = '2026-10-08', late_fee = 1.00 WHERE loan_id = 5537;

-- Book 6: out, nobody waiting -> Checked out
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5538, 6, 214, '2026-10-25', '2026-11-08');

-- Book 7: 1 of 2 copies out, the returned copy set aside -> On hold
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5539, 7, 207, '2026-10-05', '2026-10-19'),
    (5540, 7, 210, '2026-10-18', '2026-11-01');
INSERT INTO holds (hold_id, book_id, member_id, request_time) VALUES
    (93, 7, 213, '2026-10-19 08:30');
UPDATE loans SET return_date = '2026-10-26', late_fee = 1.75 WHERE loan_id = 5539;   -- hold 93 -> ready

-- Book 8: never borrowed -> Available

-- Book 9: hold missed its pickup and expired, then someone else checked it out -> Checked out
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5541, 9, 208, '2026-10-01', '2026-10-15');
INSERT INTO holds (hold_id, book_id, member_id, request_time) VALUES
    (94, 9, 214, '2026-10-03 11:11');
UPDATE loans SET return_date = '2026-10-14' WHERE loan_id = 5541;                   -- hold 94 -> ready
UPDATE holds SET notified_time = '2026-10-14 10:00:00', pickup_by = '2026-10-16' WHERE hold_id = 94;
UPDATE holds SET status = 'expired' WHERE hold_id = 94;                             -- missed pickup
INSERT INTO loans (loan_id, book_id, member_id, checkout_date, due_date) VALUES
    (5542, 9, 209, '2026-10-24', '2026-11-07');

-- Book 10: never borrowed -> Available

COMMIT;
