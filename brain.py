import math
import heapq
from typing import List, Tuple, Dict

class Point:
    def __init__(self, x: float, y: float):
        self.x = x
        self.y = y

def manhattan_distance(p1: Point, p2: Point) -> float:
    return abs(p1.x - p2.x) + abs(p1.y - p2.y)

def get_mst_edges(points: List[Point]) -> List[Tuple[Point, Point]]:
    if not points:
        return []
    
    unvisited = set(points[1:])
    visited = [points[0]]
    edges = []
    
    while unvisited:
        min_dist = float('inf')
        best_edge = None
        best_point = None
        
        for v in visited:
            for u in unvisited:
                dist = manhattan_distance(v, u)
                if dist < min_dist:
                    min_dist = dist
                    best_edge = (v, u)
                    best_point = u
                    
        if best_point:
            visited.append(best_point)
            unvisited.remove(best_point)
            edges.append(best_edge)
            
    return edges

def get_grid_coords(values: List[float], tol: float = 1e-4) -> List[float]:
    values.sort()
    unique = []
    for v in values:
        if not unique or abs(v - unique[-1]) > tol:
            unique.append(v)
    return unique

def find_closest_index(val: float, coords: List[float]) -> int:
    idx = 0
    min_diff = float('inf')
    for i, c in enumerate(coords):
        diff = abs(c - val)
        if diff < min_diff:
            min_diff = diff
            idx = i
    return idx

def a_star_route(start: Point, end: Point, xs: List[float], ys: List[float]) -> List[Dict[str, Dict[str, float]]]:
    start_idx = (find_closest_index(start.x, xs), find_closest_index(start.y, ys))
    end_idx = (find_closest_index(end.x, xs), find_closest_index(end.y, ys))
    
    def h(idx):
        return abs(xs[idx[0]] - xs[end_idx[0]]) + abs(ys[idx[1]] - ys[end_idx[1]])
        
    open_set = []
    heapq.heappush(open_set, (0, start_idx))
    
    came_from = {}
    g_score = {start_idx: 0}
    
    while open_set:
        _, current = heapq.heappop(open_set)
        
        if current == end_idx:
            break
            
        cx, cy = current
        neighbors = []
        if cx > 0: neighbors.append((cx - 1, cy))
        if cx < len(xs) - 1: neighbors.append((cx + 1, cy))
        if cy > 0: neighbors.append((cx, cy - 1))
        if cy < len(ys) - 1: neighbors.append((cx, cy + 1))
        
        for nxt in neighbors:
            nx, ny = nxt
            dist = abs(xs[cx] - xs[nx]) + abs(ys[cy] - ys[ny])
            tentative_g = g_score[current] + dist
            
            if current in came_from:
                prev = came_from[current]
                # small penalty for changing direction (to encourage long straight lines)
                if (prev[0] != nx) and (prev[1] != ny):
                    tentative_g += 0.01

            if tentative_g < g_score.get(nxt, float('inf')):
                came_from[nxt] = current
                g_score[nxt] = tentative_g
                f_score = tentative_g + h(nxt)
                heapq.heappush(open_set, (f_score, nxt))
                
    path_nodes = []
    curr = end_idx
    if curr not in came_from and start_idx != end_idx:
        # Fallback 
        return [{"start": {"x": start.x, "y": start.y}, "end": {"x": end.x, "y": end.y}}]

    while curr in came_from:
        path_nodes.append(curr)
        curr = came_from[curr]
    path_nodes.append(start_idx)
    path_nodes.reverse()
    
    segments = []
    for i in range(len(path_nodes) - 1):
        idx1 = path_nodes[i]
        idx2 = path_nodes[i+1]
        p1_x, p1_y = xs[idx1[0]], ys[idx1[1]]
        p2_x, p2_y = xs[idx2[0]], ys[idx2[1]]
        
        if not (math.isclose(p1_x, p2_x) and math.isclose(p1_y, p2_y)):
            segments.append({
                "start": {"x": p1_x, "y": p1_y},
                "end": {"x": p2_x, "y": p2_y}
            })
            
    return segments

def generate_tree_routing(points_data: List[Dict[str, float]], xmin: float, ymin: float, xmax: float, ymax: float) -> List[Dict[str, Dict[str, float]]]:
    if not points_data:
        return []
        
    points = [Point(pd['x'], pd['y']) for pd in points_data]
    
    # Filter points inside bounding box
    points = [p for p in points if xmin - 1e-6 <= p.x <= xmax + 1e-6 and ymin - 1e-6 <= p.y <= ymax + 1e-6]
    
    if len(points) < 2:
        return []

    xs = get_grid_coords([p.x for p in points] + [xmin, xmax])
    ys = get_grid_coords([p.y for p in points] + [ymin, ymax])
    
    mst_edges = get_mst_edges(points)
    all_segments = []
    
    for u, v in mst_edges:
        segs = a_star_route(u, v, xs, ys)
        all_segments.extend(segs)

    return all_segments
