"""
test_routing.py
Quick test to verify the FastAPI backend routing logic.
Run: python test_routing.py
"""

import json
import urllib.request
import urllib.error

BASE_URL = "http://localhost:8000"

# ─── Test data: 3x3 sprinkler grid inside a 9000x6000 rectangle ──────────────
test_payload = {
    "xmin": 0.0,
    "ymin": 0.0,
    "xmax": 9000.0,
    "ymax": 6000.0,
    "points": [
        # Row 1
        {"x": 1500.0, "y": 1500.0},
        {"x": 4500.0, "y": 1500.0},
        {"x": 7500.0, "y": 1500.0},
        # Row 2
        {"x": 1500.0, "y": 3000.0},
        {"x": 4500.0, "y": 3000.0},
        {"x": 7500.0, "y": 3000.0},
        # Row 3
        {"x": 1500.0, "y": 4500.0},
        {"x": 4500.0, "y": 4500.0},
        {"x": 7500.0, "y": 4500.0},
    ]
}

def test_health():
    print("─── Health Check ───────────────────────")
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/health")
        data = json.loads(req.read())
        print(f"  ✓  Status: {data}")
    except Exception as e:
        print(f"  ✗  ERROR: {e}")
        print("     Make sure the server is running: python -m uvicorn main:app --port 8000")
        return False
    return True

def test_route():
    print("\n─── Route Generation Test ──────────────")
    print(f"  Input : 9 sprinklers in a 3×3 grid")
    print(f"  Rect  : (0,0) → (9000,6000)")

    body = json.dumps(test_payload).encode("utf-8")
    req  = urllib.request.Request(
        f"{BASE_URL}/route",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )

    try:
        resp = urllib.request.urlopen(req)
        data = json.loads(resp.read())

        print(f"\n  ✓  Message       : {data['message']}")
        print(f"  ✓  Total segments: {data['total_segments']}")
        print("\n  Segments:")
        for i, seg in enumerate(data["segments"]):
            s = seg["start"]
            e = seg["end"]
            print(f"    [{i+1:2d}]  ({s['x']:8.1f}, {s['y']:8.1f})  →  ({e['x']:8.1f}, {e['y']:8.1f})")

    except urllib.error.HTTPError as e:
        print(f"  ✗  HTTP {e.code}: {e.read().decode()}")
    except Exception as e:
        print(f"  ✗  ERROR: {e}")

def test_edge_cases():
    print("\n─── Edge Case: Points outside rectangle ─")
    bad_payload = {
        "xmin": 0.0, "ymin": 0.0, "xmax": 5000.0, "ymax": 5000.0,
        "points": [
            {"x": -100.0, "y": 1000.0},   # outside
            {"x": 6000.0, "y": 1000.0},   # outside
        ]
    }
    body = json.dumps(bad_payload).encode("utf-8")
    req  = urllib.request.Request(
        f"{BASE_URL}/route",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        resp = urllib.request.urlopen(req)
        data = json.loads(resp.read())
        print(f"  Response: {data}")
    except urllib.error.HTTPError as e:
        detail = json.loads(e.read().decode()).get("detail", "")
        print(f"  ✓  Correctly rejected with 400: {detail}")

if __name__ == "__main__":
    print("╔═══════════════════════════════════════════╗")
    print("║   Sprinkler Routing Backend — Test Suite  ║")
    print("╚═══════════════════════════════════════════╝\n")

    if test_health():
        test_route()
        test_edge_cases()

    print("\n─── Done ────────────────────────────────────")
