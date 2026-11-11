#!/usr/bin/env python3
"""Writes made-up demo data for screenshots into the folder given as the first argument:
chat.db (a fake Messages database), contacts.json, clipboard.json, pins.json, config.json.
Nothing here comes from a real Mac."""
import json, os, sqlite3, sys, time

out = sys.argv[1]
os.makedirs(os.path.join(out, "data"), exist_ok=True)
os.makedirs(os.path.join(out, "config"), exist_ok=True)
APPLE = 978307200
now = time.time()
ns = lambda minutes_ago: int((now - minutes_ago * 60 - APPLE) * 1e9)

people = {"+15550101": "Sarah Chen", "+15550102": "Alex Rivera", "+15550103": "Priya Patel",
          "+15550104": "Dad", "+15550105": "Jordan Lee", "+15550106": "Mia Thompson"}
json.dump(people, open(os.path.join(out, "contacts.json"), "w"))

db_path = os.path.join(out, "chat.db")
if os.path.exists(db_path):
    os.remove(db_path)
db = sqlite3.connect(db_path)
db.executescript("""
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, style INTEGER, is_filtered INTEGER DEFAULT 0);
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER,
  cache_has_attachments INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, is_read INTEGER DEFAULT 1,
  is_finished INTEGER DEFAULT 1, is_system_message INTEGER DEFAULT 0, date INTEGER, handle_id INTEGER,
  associated_message_type INTEGER DEFAULT 0, is_sent INTEGER DEFAULT 1, is_delivered INTEGER DEFAULT 1,
  date_read INTEGER DEFAULT 0, error INTEGER DEFAULT 0);
""")
chats = [  # handle, group name, [(minutes ago, from me, text, unread)]
    ("+15550101", "", [(50, 1, "Are you coming to the thing tonight?", 0), (40, 0, "Yes!! What time?", 0),
                       (4, 0, "Starts at 7 🎉", 1), (3, 0, "Are you still coming tonight? 🎉", 1)]),
    ("+15550102", "", [(70, 1, "Can you send the deck?", 0), (62, 0, "Sent you the deck, check your email", 0)]),
    ("chat-lunch", "Lunch Crew", [(130, 0, "Tacos at 12:30?", 0)]),
    ("+15550103", "", [(200, 1, "That was hilarious", 0), (190, 0, "Haha yes! Same time next week?", 0)]),
    ("+15550104", "", [(600, 0, "Call me when you're free", 0)]),
    ("+15550105", "", [(1500, 0, "Thanks for the help today 🙏", 0)]),
    ("+15550106", "", [(3000, 1, "Happy birthday!! 🎂", 0), (2900, 0, "Thank you!! ❤️", 0)]),
]
mid = 1
for cid, (handle, group, msgs) in enumerate(chats, start=1):
    db.execute("INSERT INTO chat VALUES (?,?,?,?,?,0)", (cid, f"demo-{cid}", handle, group, 43 if group else 45))
    db.execute("INSERT INTO handle VALUES (?,?)", (cid, handle if not group else "+15550199"))
    db.execute("INSERT INTO chat_handle_join VALUES (?,?)", (cid, cid))
    for minutes, me, text, unread in msgs:
        d = ns(minutes)
        db.execute("INSERT INTO message (ROWID,text,is_from_me,is_read,date,handle_id,date_read) VALUES (?,?,?,?,?,?,?)",
                   (mid, text, me, 0 if unread else 1, d, cid, d + 60_000_000_000 if me else 0))
        db.execute("INSERT INTO chat_message_join VALUES (?,?,?)", (cid, mid, d))
        mid += 1
db.commit()

t = now - APPLE
json.dump([
    {"id": "c1", "kind": "text", "value": "https://github.com/swiftlang/swift", "app": "Safari", "date": t - 60},
    {"id": "c2", "kind": "text", "value": "brew install ripgrep fd bat", "app": "Terminal", "date": t - 540},
    {"id": "c3", "kind": "text", "value": "Meeting notes\nAgenda: Q3 launch plan\nOwners: TBD", "app": "Notes", "date": t - 3600},
    {"id": "c4", "kind": "file", "value": "/System/Applications/Calculator.app", "app": "Finder", "date": t - 7200},
    {"id": "c5", "kind": "text", "value": "Flight BA 0117 · Seat 14A · Gate closes 09:40", "app": "Mail", "date": t - 86400},
], open(os.path.join(out, "data", "clipboard.json"), "w"))

json.dump(["app./System/Applications/Notes.app", "app./Applications/Safari.app", "keyword.c"],
          open(os.path.join(out, "data", "pins.json"), "w"))
json.dump({"places": ["~/Desktop", "~/Downloads", "~/Documents", "/Applications"], "launchAtLogin": False},
          open(os.path.join(out, "config", "config.json"), "w"))
print("demo data in", out)
