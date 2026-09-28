#!/usr/bin/env python3
"""booking-slots: two people ask for one slot at once; the unsafe handler says yes twice, the safe one tells the second who has it."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from appplayer import AppPlayer  # noqa: E402
from mcpclient import Server  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "booking_server")
CAP = os.path.join(HERE, "captures")
SERVER_ID = "com.makemind.sample.booking"

with Server(["dart", "run", "bin/server.dart"], cwd=SERVER) as s:
    unsafe = s.call("book.stampede", {"at": "10:30", "first": "Smith", "second": "Jones", "mode": "unsafe"})
    assert unsafe["doubleCount"] == 1, unsafe
    s.call("book.reset")
    safe = s.call("book.stampede", {"at": "10:30", "first": "Smith", "second": "Jones", "mode": "safe"})
    assert safe["doubleCount"] == 0, safe

ap = AppPlayer()
ap.register_server(SERVER_ID, "Booking slots", cwd=SERVER)
ap.restart()
ap.open_server(SERVER_ID)
ap.wait_text("TOLD YES TWICE")
ap.tap("Two ask at once · unsafe")
ap.wait_text("more than one person")
ap.shot(f"{CAP}/01_double_booked.png")
ap.tap("Reset")
ap.wait_text("cleared")
ap.tap("Two ask at once · safe")
ap.wait_text("nobody was told yes twice")
ap.shot(f"{CAP}/02_one_of_them.png")
print("booking-slots: the race reproduced, then closed, on screen")
