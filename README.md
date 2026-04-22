# ZWCAD Sprinkler Auto-Routing System

Automatically generates sprinkler pipe routing inside a selected rectangle in ZWCAD,
powered by a Python FastAPI backend.

---

## 📁 Project Structure

```
sprinkler_system/
├── backend/
│   ├── main.py              ← FastAPI backend (routing logic)
│   └── requirements.txt     ← Python dependencies
├── autolisp/
│   └── SPRINKLER_ROUTE.lsp  ← ZWCAD AutoLISP plugin
├── START_SERVER.bat          ← One-click server launcher (Windows)
├── test_routing.py           ← Backend test script
└── README.md
```

---

## ⚙️ Requirements

| Component | Requirement |
|-----------|-------------|
| ZWCAD     | 2022 or newer (with AutoLISP support) |
| Python    | 3.9 or newer |
| curl      | Built-in on Windows 10+; add to PATH on older systems |

---

## 🚀 Setup & Usage

### Step 1 — Start the FastAPI Backend

**Option A:** Double-click `START_SERVER.bat`

**Option B:** Manual
```bash
cd backend
pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Verify it works: open `http://localhost:8000` in your browser.
You should see: `{"status":"Sprinkler Routing API is running","version":"1.0.0"}`

---

### Step 2 — Load the Plugin in ZWCAD

1. Open ZWCAD.
2. Type `APPLOAD` at the command prompt → press Enter.
3. Browse to `autolisp/SPRINKLER_ROUTE.lsp` → click **Load**.
4. You should see: `[SPRINKLER_ROUTE] Plugin loaded successfully.`

> **Tip:** To auto-load every session, add the `.lsp` path to ZWCAD's Startup Suite
> in the APPLOAD dialog.

---

### Step 3 — Run the Command

1. Type `SPRINKLER_ROUTE` at the command prompt → press Enter.
2. **Click on** the closed polyline that represents the room boundary.
3. **Enter** the layer name that contains the sprinkler INSERT blocks
   (e.g., `SPRINKLERS` or `SP-HEAD`).
4. The plugin will:
   - Scan all INSERT blocks on that layer inside the rectangle.
   - Send coordinates to the backend.
   - Receive routing segments.
   - Draw pipe lines on layer `ROUTING_PIPE` (blue, auto-created).

---

## 🧪 Testing the Backend

Without ZWCAD, you can test the backend logic:

```bash
# Make sure server is running first
python test_routing.py
```

---

## 📐 Routing Logic

```
Rectangle (width ≥ height)  →  Horizontal trunk
Rectangle (height > width)  →  Vertical trunk

Trunk:      Full-length center line (horizontal or vertical)
Branches:   Perpendicular lines per column/row of sprinklers
Sub-branches: Short lines connecting sprinkler rows/columns
```

Example — 3×3 grid in a wide room:

```
  ┌─────────────────────────────┐
  │    │           │           │  ← branch lines (vertical)
  │    ●           ●           ●
  │    │           │           │
  ├────┼───────────┼───────────┤  ← main trunk (horizontal)
  │    │           │           │
  │    ●           ●           ●
  │    │           │           │
  └─────────────────────────────┘
```

---

## 🔧 API Reference

### POST /route

**Request body:**
```json
{
  "xmin": 0.0,
  "ymin": 0.0,
  "xmax": 9000.0,
  "ymax": 6000.0,
  "points": [
    {"x": 1500.0, "y": 1500.0},
    {"x": 4500.0, "y": 1500.0}
  ]
}
```

**Response:**
```json
{
  "segments": [
    {
      "start": {"x": 0.0,    "y": 3000.0},
      "end":   {"x": 9000.0, "y": 3000.0}
    }
  ],
  "message": "Routing generated successfully for 2 sprinklers.",
  "total_segments": 5
}
```

---

## ❓ Troubleshooting

| Problem | Solution |
|---------|----------|
| `No response from backend` | Make sure `START_SERVER.bat` is running and port 8000 is free |
| `No blocks found on layer` | Check layer name spelling (case-sensitive) |
| `curl not found` | Install curl and add to Windows PATH |
| `Invalid polyline` | Make sure you selected a LWPOLYLINE (rectangle drawn with RECTANG command) |
| Segments not drawing | Check `ROUTING_PIPE` layer is not frozen/locked |

---

## 📝 Notes

- All routing is **orthogonal** (horizontal + vertical lines only).
- All segments are **clamped inside** the selected rectangle.
- The plugin supports **multiple rooms** — run `SPRINKLER_ROUTE` again for each rectangle.
- The `ROUTING_PIPE` layer is created automatically with **blue** color.
