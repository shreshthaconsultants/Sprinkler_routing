from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List
import uvicorn

from brain import generate_tree_routing

app = FastAPI(title="Sprinkler Routing API", version="1.0.0")

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

# ─── Routes ───────────────────────────────────────────────────────────────────

@app.get("/")
def root():
    return {"status": "Sprinkler Routing API is running", "version": "1.0.0"}

@app.post("/route", response_model=RouteResponse)
def route(req: RouteRequest):
    if req.xmax <= req.xmin or req.ymax <= req.ymin:
        raise HTTPException(status_code=400, detail="Invalid rectangle bounds.")
    if not req.points:
        raise HTTPException(status_code=400, detail="No sprinkler points provided.")

    points_data = [{"x": p.x, "y": p.y} for p in req.points]
    
    raw_segments = generate_tree_routing(
        points_data, req.xmin, req.ymin, req.xmax, req.ymax
    )
    
    segs = []
    for s in raw_segments:
        segs.append(LineSegment(
            start=Point(x=s["start"]["x"], y=s["start"]["y"]),
            end=Point(x=s["end"]["x"], y=s["end"]["y"])
        ))

    return RouteResponse(
        segments=segs,
        message=f"Routing generated successfully for {len(req.points)} sprinklers.",
        total_segments=len(segs)
    )

@app.get("/health")
def health():
    return {"status": "ok"}

# ─── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
