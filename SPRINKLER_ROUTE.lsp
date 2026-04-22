;; =============================================================================
;;  SPRINKLER_ROUTE.lsp   (v2.1 — point-in-polygon containment per room)
;;  AutoLISP plugin for ZWCAD — Automatic Sprinkler Pipe Routing
;;  Backend : FastAPI  http://localhost:8050/route_multi
;;
;;  Key fix vs v2.0:
;;    Each room polyline can be ANY shape (L-shape, notched, slanted, etc.).
;;    We do real point-in-polygon tests so a sprinkler is assigned to the
;;    room whose polyline actually contains it — never to a neighbour.
;;
;;  Workflow:
;;    1. Click the OUTER architecture rectangle
;;    2. Type the SPRINKLER block layer name
;;    3. Type the INSIDE-BOX (room polylines) layer name
;; =============================================================================

;; ─── Utility: Ensure a layer exists ─────────────────────────────────────────
(defun ensure-layer (layer-name color / )
  (if (not (tblsearch "LAYER" layer-name))
    (command "._LAYER" "N" layer-name "C" (itoa color) layer-name "")
    (command "._LAYER" "C" (itoa color) layer-name "")
  )
)

;; ─── Utility: Get polyline vertices (list of (x y) pairs) ───────────────────
(defun get-pline-vertices (ename / en pt-list pair)
  (setq en (entget ename))
  (setq pt-list '())
  (foreach pair en
    (if (= (car pair) 10)
      (setq pt-list (append pt-list (list (list (car (cdr pair))
                                                 (cadr (cdr pair))))))
    )
  )
  pt-list
)

;; ─── Utility: Bounding box of a list of (x y) pairs ─────────────────────────
(defun verts-bbox (verts / xs ys)
  (if (null verts)
    nil
    (progn
      (setq xs (mapcar 'car  verts))
      (setq ys (mapcar 'cadr verts))
      (list (apply 'min xs) (apply 'min ys)
            (apply 'max xs) (apply 'max ys))
    )
  )
)

;; ─── Utility: Check point inside axis-aligned rectangle ─────────────────────
(defun pt-inside-rect (px py xmin ymin xmax ymax / tol)
  (setq tol 1e-6)
  (and (> px (- xmin tol)) (< px (+ xmax tol))
       (> py (- ymin tol)) (< py (+ ymax tol)))
)

;; ─── Utility: Point-in-polygon via ray-casting ──────────────────────────────
;;  verts : list of (x y) pairs (polygon, auto-closed)
;;  Returns T if the point (px,py) is strictly inside.
(defun pt-inside-poly (px py verts / n i j inside xi yi xj yj intersect)
  (setq n (length verts))
  (setq inside nil)
  (setq i 0)
  (setq j (1- n))
  (while (< i n)
    (setq xi (car  (nth i verts)))
    (setq yi (cadr (nth i verts)))
    (setq xj (car  (nth j verts)))
    (setq yj (cadr (nth j verts)))

    (setq intersect
      (and (/= (> yi py) (> yj py))
           (< px (+ xi (/ (* (- xj xi) (- py yi))
                          (if (zerop (- yj yi)) 1e-12 (- yj yi)))))))
    (if intersect (setq inside (not inside)))
    (setq j i)
    (setq i (1+ i))
  )
  inside
)

;; ─── Utility: Number to string ───────────────────────────────────────────────
(defun num->str (n)
  (if (= (type n) 'REAL) (rtos n 2 6) (itoa n))
)

;; ─── Utility: Build JSON point entry ─────────────────────────────────────────
(defun json-point (px py)
  (strcat "{\"x\":" (num->str px) ",\"y\":" (num->str py) "}")
)

;; ─── Build JSON body for ONE box (bbox + its own sprinkler points) ──────────
(defun build-box-json (xmin ymin xmax ymax pt-list / body i pt)
  (setq body
    (strcat "{"
      "\"xmin\":" (num->str xmin) ","
      "\"ymin\":" (num->str ymin) ","
      "\"xmax\":" (num->str xmax) ","
      "\"ymax\":" (num->str ymax) ","
      "\"points\":["))
  (setq i 0)
  (foreach pt pt-list
    (if (> i 0) (setq body (strcat body ",")))
    (setq body (strcat body (json-point (car pt) (cadr pt))))
    (setq i (1+ i))
  )
  (strcat body "]}")
)

;; ─── Build JSON body for the full multi-box request ─────────────────────────
;;  boxes-data : list of (xmin ymin xmax ymax pt-list)
(defun build-multi-json (boxes-data / body i box)
  (setq body "{\"boxes\":[")
  (setq i 0)
  (foreach box boxes-data
    (if (> i 0) (setq body (strcat body ",")))
    (setq body (strcat body
                 (build-box-json
                   (nth 0 box) (nth 1 box)
                   (nth 2 box) (nth 3 box)
                   (nth 4 box))))
    (setq i (1+ i))
  )
  (strcat body "]}")
)

;; ─── HTTP POST via temp file + curl ──────────────────────────────────────────
(defun http-post (url json-body / tmp-in tmp-out cmd result fh line)
  (setq tmp-in  (strcat (getenv "TEMP") "\\spr_req.json"))
  (setq tmp-out (strcat (getenv "TEMP") "\\spr_res.json"))

  (setq fh (open tmp-in "w"))
  (write-line json-body fh)
  (close fh)

  (setq cmd
    (strcat "curl -s -X POST "
            "-H \"Content-Type: application/json\" "
            "-d @\"" tmp-in "\" "
            "\"" url "\" "
            "-o \"" tmp-out "\""))

  (command "._SHELL" cmd)
  (command "._DELAY" "2000")

  (if (findfile tmp-out)
    (progn
      (setq fh (open tmp-out "r"))
      (setq result "")
      (setq line (read-line fh))
      (while line
        (setq result (strcat result line))
        (setq line (read-line fh)))
      (close fh)
      result)
    nil
  )
)

;; ─── Extract number after a key ──────────────────────────────────────────────
(defun extract-number-after (key str / pos val-start val-end)
  (setq pos (vl-string-search key str))
  (if pos
    (progn
      (setq val-start (+ pos (strlen key)))
      (setq val-end val-start)
      (while (and (< val-end (strlen str))
                  (not (member (substr str (1+ val-end) 1)
                               '("," "}" " " "]"))))
        (setq val-end (1+ val-end)))
      (atof (substr str (1+ val-start) (- val-end val-start))))
    nil
  )
)

;; ─── Parse all segments in a flat JSON string ────────────────────────────────
(defun parse-segments (json-str / seg-list pos seg-str sx sy ex ey
                                   tmp-pos end-pos end-str tmp2)
  (setq seg-list '())
  (setq pos 0)
  (while (setq pos (vl-string-search "\"start\"" json-str pos))
    (setq seg-str (substr json-str (1+ pos) 140))
    (setq sx (extract-number-after "\"x\":" seg-str))
    (setq tmp-pos (vl-string-search "\"y\":" seg-str 0))
    (if tmp-pos (setq sy (atof (substr seg-str (+ tmp-pos 5) 20))))

    (setq end-pos (vl-string-search "\"end\"" seg-str 0))
    (if end-pos
      (progn
        (setq end-str (substr seg-str (1+ end-pos) 80))
        (setq ex (extract-number-after "\"x\":" end-str))
        (setq tmp2 (vl-string-search "\"y\":" end-str 0))
        (if tmp2 (setq ey (atof (substr end-str (+ tmp2 5) 20))))
      )
    )

    (if (and sx sy ex ey)
      (setq seg-list (append seg-list (list (list sx sy ex ey))))
    )
    (setq pos (1+ pos))
  )
  seg-list
)

;; ─── Parse /route_multi response into a list of segment-lists, one per box ──
;;  Splits the JSON into chunks at each "box_index" marker, then parses each
;;  chunk independently. Returns segments in box-index order (matches send order).
(defun parse-segments-per-box (json-str / chunks pos last-pos result chunk)
  (setq chunks '())
  (setq pos (vl-string-search "\"box_index\"" json-str 0))
  (while pos
    (setq last-pos pos)
    (setq pos (vl-string-search "\"box_index\"" json-str (1+ pos)))
    (if pos
      (setq chunks (append chunks (list (substr json-str (1+ last-pos) (- pos last-pos)))))
      (setq chunks (append chunks (list (substr json-str (1+ last-pos)))))
    )
  )
  (setq result '())
  (foreach chunk chunks
    (setq result (append result (list (parse-segments chunk))))
  )
  result
)

;; ─── Get segment direction: "H" for horizontal, "V" for vertical ────────────
(defun segment-dir (seg / tol)
  (setq tol 1e-6)
  (if (< (abs (- (nth 3 seg) (nth 1 seg))) tol) "H" "V")
)

;; ─── Check if two points are within tolerance ──────────────────────────────────
(defun pts-equal (p1 p2 / tol)
  (setq tol 1e-6)
  (and (< (abs (- (car p1) (car p2))) tol)
       (< (abs (- (cadr p1) (cadr p2))) tol))
)

;; ─── Collect ALL sprinkler INSERT points on a layer (anywhere) ──────────────
;;  Returns list of (x y) pairs.
(defun collect-all-sprinklers (sprinkler-layer / ss i ent ed pt result)
  (setq result '())
  (setq ss (ssget "X" (list (cons 0 "INSERT") (cons 8 sprinkler-layer))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq ent (ssname ss i))
        (setq ed  (entget ent))
        (setq pt  (cdr (assoc 10 ed)))
        (setq result (append result
                              (list (list (car pt) (cadr pt)))))
        (setq i (1+ i))
      )
    )
  )
  result
)

;; ─── Collect room polylines on a given layer within the outer rect ──────────
;;  Each returned item is the vertex list (list of (x y) pairs).
(defun collect-room-polys (box-layer oxmin oymin oxmax oymax
                           / ss i ent verts bb cx cy result)
  (setq result '())
  (setq ss (ssget "X" (list (cons 8 box-layer)
                            (cons 0 "LWPOLYLINE,POLYLINE"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq ent (ssname ss i))
        (setq verts (get-pline-vertices ent))
        (if (and verts (>= (length verts) 3))
          (progn
            (setq bb (verts-bbox verts))
            (setq cx (/ (+ (nth 0 bb) (nth 2 bb)) 2.0))
            (setq cy (/ (+ (nth 1 bb) (nth 3 bb)) 2.0))
            ;; keep polys whose centroid is inside the outer rect
            (if (pt-inside-rect cx cy oxmin oymin oxmax oymax)
              (setq result (append result (list verts)))
            )
          )
        )
        (setq i (1+ i))
      )
    )
  )
  result
)

;; ─── Filter sprinkler points that lie inside a given polygon ────────────────
(defun pts-in-poly (all-pts verts / result pt)
  (setq result '())
  (foreach pt all-pts
    (if (pt-inside-poly (car pt) (cadr pt) verts)
      (setq result (append result (list pt)))
    )
  )
  result
)

;; ─── Slightly shrink a bbox so routing stays strictly inside the polygon ────
(defun shrink-bbox (bb margin)
  (list (+ (nth 0 bb) margin)
        (+ (nth 1 bb) margin)
        (- (nth 2 bb) margin)
        (- (nth 3 bb) margin))
)

;; ─── Find dominant angle of polygon (angle of longest edge, in radians) ─────
(defun pline-angle (verts / n i j best-len best-ang p1 p2 dx dy len)
  (setq n (length verts))
  (setq best-len 0.0)
  (setq best-ang 0.0)
  (setq i 0)
  (while (< i n)
    (setq j (if (= i (1- n)) 0 (1+ i)))
    (setq p1 (nth i verts))
    (setq p2 (nth j verts))
    (setq dx (- (car p2) (car p1)))
    (setq dy (- (cadr p2) (cadr p1)))
    (setq len (sqrt (+ (* dx dx) (* dy dy))))
    (if (> len best-len)
      (progn
        (setq best-len len)
        (setq best-ang (atan dy dx))
      )
    )
    (setq i (1+ i))
  )
  best-ang
)

;; ─── Rotate point (px py) by ang radians around center (cx cy) ──────────────
(defun rot-pt (px py cx cy ang / cs sn dx dy)
  (setq cs (cos ang))
  (setq sn (sin ang))
  (setq dx (- px cx))
  (setq dy (- py cy))
  (list (+ cx (- (* dx cs) (* dy sn)))
        (+ cy (+ (* dx sn) (* dy cs))))
)

;; ─── Rotate every vertex in a list around (cx cy) by ang ────────────────────
(defun rotate-verts (verts cx cy ang / result v rp)
  (setq result '())
  (foreach v verts
    (setq rp (rot-pt (car v) (cadr v) cx cy ang))
    (setq result (append result (list rp)))
  )
  result
)

;; ─── Group sequential H/V segments into polylines ───────────────────────────
;;  Returns list of polylines, each polyline = list of (x y) points.
(defun build-polylines (segments / pls cur-dir cur-pts last-end seg sd i)
  (setq pls '())
  (setq cur-pts '())
  (setq cur-dir nil)
  (setq last-end nil)
  (setq i 0)
  (while (< i (length segments))
    (setq seg (nth i segments))
    (setq sd (segment-dir seg))
    (if (null cur-dir)
      (progn
        (setq cur-dir sd)
        (setq cur-pts (list (list (nth 0 seg) (nth 1 seg))
                            (list (nth 2 seg) (nth 3 seg))))
        (setq last-end (list (nth 2 seg) (nth 3 seg)))
      )
      (if (and (= sd cur-dir)
               (pts-equal last-end (list (nth 0 seg) (nth 1 seg))))
        (progn
          (setq cur-pts (append cur-pts (list (list (nth 2 seg) (nth 3 seg)))))
          (setq last-end (list (nth 2 seg) (nth 3 seg)))
        )
        (progn
          (if (>= (length cur-pts) 2)
            (setq pls (append pls (list cur-pts)))
          )
          (setq cur-dir sd)
          (setq cur-pts (list (list (nth 0 seg) (nth 1 seg))
                              (list (nth 2 seg) (nth 3 seg))))
          (setq last-end (list (nth 2 seg) (nth 3 seg)))
        )
      )
    )
    (setq i (1+ i))
  )
  (if (>= (length cur-pts) 2)
    (setq pls (append pls (list cur-pts)))
  )
  pls
)

;; ─── Rotate every point in every polyline by ang around (cx cy) ─────────────
(defun rotate-polylines (pls cx cy ang / result poly newpoly pt rp)
  (setq result '())
  (foreach poly pls
    (setq newpoly '())
    (foreach pt poly
      (setq rp (rot-pt (car pt) (cadr pt) cx cy ang))
      (setq newpoly (append newpoly (list rp)))
    )
    (setq result (append result (list newpoly)))
  )
  result
)

;; ─── Draw a list of polylines on a layer ────────────────────────────────────
(defun draw-polylines (polys layer-name / pl pt prev-layer count)
  (ensure-layer layer-name 1)
  (setq prev-layer (getvar "CLAYER"))
  (setvar "CLAYER" layer-name)
  (setq count 0)
  (foreach pl polys
    (command "._PLINE")
    (foreach pt pl
      (command (list (car pt) (cadr pt) 0.0))
    )
    (command "")
    (setq count (1+ count))
  )
  (setvar "CLAYER" prev-layer)
  count
)

;; ─── MAIN COMMAND ───────────────────────────────────────────────────────────
(defun C:SPRINKLER_ROUTE ( / sel-ent ent-type outer-verts outer-bb
                            oxmin oymin oxmax oymax
                            sprinkler-layer box-layer
                            all-sprinklers rooms
                            room-verts room-bb room-pts
                            room-idx routed-count
                            theta cx cy local-verts local-pts local-bb
                            boxes-data room-info segs-per-box
                            json-body response segs polys world-polys
                            all-polys total-pipes)

  (princ "\n╔═══════════════════════════════════════════════════════╗")
  (princ "\n║        SPRINKLER AUTO ROUTING SYSTEM v2.1             ║")
  (princ "\n║        Shrestha Consultants - Design Module           ║")
  (princ "\n║        Intelligent Pipe Routing & Optimization        ║")
  (princ "\n╚═══════════════════════════════════════════════════════╝")
  (princ "\n")

  ;; ── Step 1: Outer architecture rectangle ────────────────────────────────
  (princ "\n[STEP 1/5] Select Project Boundary")
  (princ "\n───────────────────────────────────────────────────────")
  (setq sel-ent (car (entsel "\n  ▸ Click on the outer boundary polyline: ")))
  (if (null sel-ent)
    (progn (princ "\n\n✗ ERROR: No boundary selected. Operation cancelled.") (exit)))

  (setq ent-type (cdr (assoc 0 (entget sel-ent))))
  (if (not (or (= ent-type "LWPOLYLINE") (= ent-type "POLYLINE")))
    (progn (princ "\n✗ ERROR: Selected object must be a polyline. Please select a valid polyline.")
           (exit)))

  (setq outer-verts (get-pline-vertices sel-ent))
  (setq outer-bb (verts-bbox outer-verts))
  (if (null outer-bb)
    (progn (princ "\n✗ ERROR: Cannot read polyline vertices. Ensure polyline is valid.") (exit)))

  (setq oxmin (nth 0 outer-bb)  oymin (nth 1 outer-bb)
        oxmax (nth 2 outer-bb)  oymax (nth 3 outer-bb))

  (princ (strcat "\n  ✓ Boundary imported. Area: (" (num->str oxmin) "," (num->str oymin)
                 ") to (" (num->str oxmax) "," (num->str oymax) ")"))

  ;; ── Step 2: Sprinkler layer ─────────────────────────────────────────────
  (princ "\n\n[STEP 2/5] Configure Sprinkler Layer")
  (princ "\n───────────────────────────────────────────────────────")
  (setq sprinkler-layer (getstring T "\n  ▸ Enter sprinkler block layer name: "))
  (if (or (null sprinkler-layer) (= sprinkler-layer ""))
    (progn (princ "\n✗ ERROR: Layer name cannot be empty.") (exit)))

  ;; ── Step 3: Inside-box (room polylines) layer ──────────────────────────
  (princ "\n\n[STEP 3/5] Configure Room Layer")
  (princ "\n───────────────────────────────────────────────────────")
  (setq box-layer (getstring T "\n  ▸ Enter room polylines layer name: "))
  (if (or (null box-layer) (= box-layer ""))
    (progn (princ "\n✗ ERROR: Layer name cannot be empty.") (exit)))

  ;; ── Step 4: Gather data ─────────────────────────────────────────────────
  (princ "\n\n[STEP 4/5] Analyzing Project Data")
  (princ "\n───────────────────────────────────────────────────────")

  (setq all-sprinklers (collect-all-sprinklers sprinkler-layer))
  (princ (strcat "\n  ✓ Found " (itoa (length all-sprinklers)) " sprinkler device(s)"))

  (setq rooms (collect-room-polys box-layer oxmin oymin oxmax oymax))
  (princ (strcat "\n  ✓ Found " (itoa (length rooms)) " room zone(s)"))

  (if (null rooms)
    (progn (princ "\n\n✗ ERROR: No room zones detected. Ensure room layer is correctly named.") (exit)))
  (if (null all-sprinklers)
    (progn (princ "\n\n✗ ERROR: No sprinkler devices detected. Ensure sprinkler layer is correctly named.") (exit)))

  ;; ── Build per-room data in local (rotated) frame ───────────────────────
  ;;  For every room with 2+ sprinklers:
  ;;    theta  = angle of longest edge
  ;;    cx,cy  = bbox center
  ;;    local frame = rotate verts + sprinklers by -theta around (cx,cy)
  ;;  Send ALL rooms in ONE /route_multi call (one curl, one terminal popup).
  ;;  Then rotate each room's returned segments back by +theta around (cx,cy).
  (setq boxes-data '())
  (setq room-info  '())   ;; parallel list of (theta cx cy) for each box sent
  (setq room-idx 0)

  (princ "\n\n[STEP 5/5] Generate Optimal Routing (per-room oriented)")
  (princ "\n───────────────────────────────────────────────────────")

  (foreach room-verts rooms
    (setq room-bb (verts-bbox room-verts))
    (setq room-pts (pts-in-poly all-sprinklers room-verts))

    (princ (strcat "\n    Zone " (itoa (1+ room-idx)) " → " (itoa (length room-pts)) " device(s)"))

    (if (>= (length room-pts) 2)
      (progn
        (setq cx (/ (+ (nth 0 room-bb) (nth 2 room-bb)) 2.0))
        (setq cy (/ (+ (nth 1 room-bb) (nth 3 room-bb)) 2.0))
        (setq theta (pline-angle room-verts))

        (setq local-verts (rotate-verts room-verts cx cy (- theta)))
        (setq local-pts   (rotate-verts room-pts   cx cy (- theta)))

        (setq local-bb (verts-bbox local-verts))
        (setq local-bb (shrink-bbox local-bb 1.0))

        (setq boxes-data
          (append boxes-data
            (list (list (nth 0 local-bb) (nth 1 local-bb)
                        (nth 2 local-bb) (nth 3 local-bb)
                        local-pts))))
        (setq room-info
          (append room-info (list (list theta cx cy))))
      )
    )
    (setq room-idx (1+ room-idx))
  )

  (if (null boxes-data)
    (progn (princ "\n\n✗ ERROR: No zone has 2+ devices. Routing requires minimum 2 devices per zone.")
           (exit)))

  (princ (strcat "\n  ✓ " (itoa (length boxes-data))
                 " zone(s) prepared in local frame."))

  ;; ── Single HTTP call with all boxes ─────────────────────────────────────
  (princ "\n  ⟳ Connecting to routing engine (single request)...")
  (setq json-body (build-multi-json boxes-data))
  (setq response (http-post "http://localhost:8050/route_multi" json-body))

  (if (null response)
    (progn
      (princ "\n\n✗ ERROR: Routing engine not responding.")
      (princ "\n  Please ensure the backend service is running on port 8050.")
      (exit)))

  (princ "\n  ✓ Route optimization complete.")

  ;; ── Per-box: parse segments, group, rotate back, accumulate ────────────
  (setq all-polys '())
  (setq routed-count 0)
  (setq segs-per-box (parse-segments-per-box response))

  (if (null segs-per-box)
    (progn (princ "\n✗ ERROR: Cannot parse routing solution from engine.") (exit)))

  (setq room-idx 0)
  (foreach segs segs-per-box
    (if segs
      (progn
        (setq theta (nth 0 (nth room-idx room-info)))
        (setq cx    (nth 1 (nth room-idx room-info)))
        (setq cy    (nth 2 (nth room-idx room-info)))
        (setq polys (build-polylines segs))
        (setq world-polys (rotate-polylines polys cx cy theta))
        (setq all-polys (append all-polys world-polys))
        (setq routed-count (1+ routed-count))
      )
    )
    (setq room-idx (1+ room-idx))
  )

  (if (null all-polys)
    (progn (princ "\n\n✗ ERROR: Engine returned no segments for any zone.") (exit)))

  (princ (strcat "\n  ✓ " (itoa routed-count) " zone(s) routed."))

  (setq total-pipes (draw-polylines all-polys "ROUTING_PIPE"))
  (princ (strcat "\n  ✓ Drew " (itoa total-pipes) " polylines on layer ROUTING_PIPE."))

  (princ "\n\n╔═══════════════════════════════════════════════════════╗")
  (princ "\n║              ✓ ROUTING COMPLETE                        ║")
  (princ "\n├───────────────────────────────────────────────────────┤")
  (princ (strcat "\n│  Zones Processed     : " (itoa routed-count) "                               │"))
  (princ (strcat "\n│  Pipe Polylines      : " (itoa total-pipes) "                              │"))
  (princ "\n│  Color Layer        : ROUTING_PIPE (Red)               │")
  (princ "\n├───────────────────────────────────────────────────────┤")
  (princ "\n│  Design is ready for review and export                │")
  (princ "\n╚═══════════════════════════════════════════════════════╝")
  (princ "\n")
)

;; ─── Load confirmation ────────────────────────────────────────────────────────
(princ "\n╔═══════════════════════════════════════════════════════╗")
(princ "\n║     SPRINKLER ROUTING MODULE v2.1 - READY             ║")
(princ "\n║     Shrestha Consultants - ZWCAD Integration         ║")
(princ "\n╚═══════════════════════════════════════════════════════╝")
(princ "\n")
(princ "\n  COMMAND:  Type 'SPRINKLER_ROUTE' in ZWCAD console")
(princ "\n")
(princ "\n  WORKFLOW:")
(princ "\n    1. Select outer boundary polyline")
(princ "\n    2. Enter sprinkler device layer name")
(princ "\n    3. Enter room zone layer name")
(princ "\n    4. Review analysis results")
(princ "\n    5. Automatic routing + visual output")
(princ "\n")
(princ "\n  FEATURES:")
(princ "\n    ✓ Intelligent path optimization (A* algorithm)")
(princ "\n    ✓ Zone-based routing analysis")
(princ "\n    ✓ Polyline grouping by direction")
(princ "\n    ✓ Point-in-polygon device assignment")
(princ "\n")
(princ)
