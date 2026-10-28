-- Run once a day:  sqlite3 library.db < daily_holds_check.sql
-- SQLite has no scheduler, so pickup deadlines are enforced by this sweep.

PRAGMA foreign_keys = ON;

-- Rule 4: holds not picked up by pickup_by expire. The holds_after_release
-- trigger then moves the next person in line to 'ready'.
UPDATE holds
SET status = 'expired'
WHERE status = 'ready' AND pickup_by < date('now', 'localtime');

-- Rule 6: who needs the next-day reminder email.
SELECT hold_id, member_name, email, title, pickup_by
FROM hold_notifications
WHERE reminder_due = 1;

-- After sending those reminders, record it:
-- UPDATE holds SET reminder_time = datetime('now', 'localtime') WHERE hold_id IN (...);
