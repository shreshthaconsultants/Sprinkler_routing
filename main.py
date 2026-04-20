from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List
import uvicorn

from brain import generate_tree_routing

app = FastAPI(title="Sprinkler Routing API", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Models ───────────────────────────────────────────────────────────────────

class Point(BaseModel):
    x: float
    y: float

class RouteRequest(BaseModel):
    xmin: float
    ymin: float
    xmax: float
    ymax: float
    points: List[Point]

class LineSegment(BaseModel):
    start: Point
    end: Point

class RouteResponse(BaseModel):
    segments: List[LineSegment]
    message: str
    total_segments: int

# ─── NEW: models for multi-box routing ───────────────────────────────────────

class Box(BaseModel):
    xmin: float
    ymin: float
    xmax: float
    ymax: float
    points: List[Point]

class MultiRouteRequest(BaseModel):
    boxes: List[Box]

class BoxResult(BaseModel):
    box_index: int
    segments: List[LineSegment]
    sprinkler_count: int

class MultiRouteResponse(BaseModel):
    results: List[BoxResult]
    message: str
    total_boxes: int
    total_segments: int

# ─── Routes ───────────────────────────────────────────────────────────────────

@app.get("/")
def root():
    return {"status": "Sprinkler Routing API is running", "version": "2.0.0"}

@app.post("/route", response_model=RouteResponse)
def route(req: RouteRequest):
    """Legacy single-box routing (kept for compatibility)."""
    if req.xmax <= req.xmin or req.ymax <= req.ymin:
        raise HTTPException(status_code=400, detail="Invalid rectangle bounds.")
    if not req.points:
        raise HTTPException(status_code=400, detail="No sprinkler points provided.")

    points_data = [{"x": p.x, "y": p.y} for p in req.points]

    raw_segments = generate_tree_routing(
        points_data, req.xmin, req.ymin, req.xmax, req.ymax
    )

    segs = [
        LineSegment(
            start=Point(x=s["start"]["x"], y=s["start"]["y"]),
            end=Point(x=s["end"]["x"], y=s["end"]["y"]),
        )
        for s in raw_segments
    ]

    return RouteResponse(
        segments=segs,
        message=f"Routing generated successfully for {len(req.points)} sprinklers.",
        total_segments=len(segs),
    )

@app.post("/route_multi", response_model=MultiRouteResponse)
def route_multi(req: MultiRouteRequest):
    """
    Routes each box independently.
    Each box gets its own separate MST + A* routing,
    so pipes from one room never merge with pipes from another room.
    """
    if not req.boxes:
        raise HTTPException(status_code=400, detail="No boxes provided.")

    results: List[BoxResult] = []
    total_segments = 0

    for idx, box in enumerate(req.boxes):
        if box.xmax <= box.xmin or box.ymax <= box.ymin:
            # Skip invalid box rather than fail the whole batch
            results.append(BoxResult(box_index=idx, segments=[], sprinkler_count=0))
            continue

        if not box.points:
            results.append(BoxResult(box_index=idx, segments=[], sprinkler_count=0))
            continue

        points_data = [{"x": p.x, "y": p.y} for p in box.points]
        raw_segments = generate_tree_routing(
            points_data, box.xmin, box.ymin, box.xmax, box.ymax
        )

        segs = [
            LineSegment(
                start=Point(x=s["start"]["x"], y=s["start"]["y"]),
                end=Point(x=s["end"]["x"], y=s["end"]["y"]),
            )
            for s in raw_segments
        ]

        total_segments += len(segs)
        results.append(BoxResult(
            box_index=idx,
            segments=segs,
            sprinkler_count=len(box.points),
        ))

    return MultiRouteResponse(
        results=results,
        message=f"Routed {len(req.boxes)} boxes independently.",
        total_boxes=len(req.boxes),
        total_segments=total_segments,
    )

@app.get("/health")
def health():
    return {"status": "ok"}

# ─── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
