;; =============================================================================
;;  SPRINKLER_ROUTE.lsp   (v2.1 — point-in-polygon containment per room)
;;  AutoLISP plugin for ZWCAD — Automatic Sprinkler Pipe Routing
;;  Backend : FastAPI  http://localhost:8000/route_multi
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

;; ─── Build JSON body for the full multi-box request ──────────────────────────
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

;; ─── Draw routing lines in ZWCAD ─────────────────────────────────────────────
(defun draw-routing (segments layer-name / seg prev-layer)
  (ensure-layer layer-name 1)
  (setq prev-layer (getvar "CLAYER"))
  (setvar "CLAYER" layer-name)
  (foreach seg segments
    (command "._LINE"
      (list (nth 0 seg) (nth 1 seg) 0.0)
      (list (nth 2 seg) (nth 3 seg) 0.0)
      ""))
  (setvar "CLAYER" prev-layer)
  (princ (strcat "\n[SPRINKLER] Drew " (itoa (length segments))
                 " pipe segments on layer " layer-name "."))
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

;; ─── MAIN COMMAND ───────────────────────────────────────────────────────────
(defun C:SPRINKLER_ROUTE ( / sel-ent ent-type outer-verts outer-bb
                            oxmin oymin oxmax oymax
                            sprinkler-layer box-layer
                            all-sprinklers rooms
                            boxes-data room-verts room-bb room-pts
                            room-idx routed-count
                            json-body response all-segs)

  (princ "\n╔══════════════════════════════════════════╗")
  (princ "\n║   SPRINKLER AUTO ROUTING  v1.0           ║")
  (princ "\n║   (per-polyline point-in-polygon)        ║")
  (princ "\n╚══════════════════════════════════════════╝")
  (princ "\n")

  ;; ── Step 1: Outer architecture rectangle ────────────────────────────────
  (princ "\n[1/5] Select the OUTER architecture rectangle.")
  (setq sel-ent (car (entsel "\n  Click on the outer boundary polyline: ")))
  (if (null sel-ent)
    (progn (princ "\n[ERROR] No entity selected. Aborting.") (exit)))

  (setq ent-type (cdr (assoc 0 (entget sel-ent))))
  (if (not (or (= ent-type "LWPOLYLINE") (= ent-type "POLYLINE")))
    (progn (princ "\n[ERROR] Outer selection must be a polyline. Aborting.")
           (exit)))

  (setq outer-verts (get-pline-vertices sel-ent))
  (setq outer-bb (verts-bbox outer-verts))
  (if (null outer-bb)
    (progn (princ "\n[ERROR] Could not read outer polyline. Aborting.") (exit)))

  (setq oxmin (nth 0 outer-bb)  oymin (nth 1 outer-bb)
        oxmax (nth 2 outer-bb)  oymax (nth 3 outer-bb))

  (princ (strcat "\n  Outer bbox: (" (num->str oxmin) "," (num->str oymin)
                 ") -> (" (num->str oxmax) "," (num->str oymax) ")"))

  ;; ── Step 2: Sprinkler layer ─────────────────────────────────────────────
  (princ "\n\n[2/5] Enter the SPRINKLER block layer name.")
  (setq sprinkler-layer (getstring T "\n  Sprinkler layer: "))
  (if (or (null sprinkler-layer) (= sprinkler-layer ""))
    (progn (princ "\n[ERROR] Empty sprinkler layer. Aborting.") (exit)))

  ;; ── Step 3: Inside-box (room polylines) layer ──────────────────────────
  (princ "\n\n[3/5] Enter the INSIDE-BOX (room polylines) layer name.")
  (setq box-layer (getstring T "\n  Inside-box layer: "))
  (if (or (null box-layer) (= box-layer ""))
    (progn (princ "\n[ERROR] Empty inside-box layer. Aborting.") (exit)))

  ;; ── Step 4: Gather data ─────────────────────────────────────────────────
  (princ "\n\n[4/5] Gathering sprinklers and room polylines...")

  (setq all-sprinklers (collect-all-sprinklers sprinkler-layer))
  (princ (strcat "\n  Total sprinklers on layer '" sprinkler-layer "': "
                 (itoa (length all-sprinklers))))

  (setq rooms (collect-room-polys box-layer oxmin oymin oxmax oymax))
  (princ (strcat "\n  Room polylines found: " (itoa (length rooms))))

  (if (null rooms)
    (progn (princ "\n[ERROR] No room polylines found. Aborting.") (exit)))
  (if (null all-sprinklers)
    (progn (princ "\n[ERROR] No sprinkler blocks found. Aborting.") (exit)))

  ;; ── Build per-room data using real point-in-polygon ─────────────────────
  (setq boxes-data '())
  (setq room-idx 0)
  (setq routed-count 0)

  (foreach room-verts rooms
    (setq room-bb (verts-bbox room-verts))
    ;; Use real polygon test, not bbox
    (setq room-pts (pts-in-poly all-sprinklers room-verts))

    (princ (strcat "\n    Room #" (itoa (1+ room-idx))
                   " : " (itoa (length room-pts)) " sprinkler(s) inside polygon"))

    (if (>= (length room-pts) 2)
      (progn
        ;; Shrink bbox by a tiny margin so A* grid stays inside the polygon
        (setq room-bb (shrink-bbox room-bb 1.0))
        (setq boxes-data
          (append boxes-data
            (list (list (nth 0 room-bb) (nth 1 room-bb)
                        (nth 2 room-bb) (nth 3 room-bb)
                        room-pts))))
        (setq routed-count (1+ routed-count))
      )
    )
    (setq room-idx (1+ room-idx))
  )

  (if (null boxes-data)
    (progn (princ "\n[ERROR] No room has >=2 sprinklers inside it. Nothing to route.")
           (exit)))

  (princ (strcat "\n  " (itoa routed-count)
                 " room(s) will be routed independently."))

  ;; ── Step 5: Send to backend & draw ──────────────────────────────────────
  (princ "\n\n[5/5] Sending request to /route_multi ...")
  (setq json-body (build-multi-json boxes-data))

  (princ "\n[DEBUG] JSON body (first 300 chars):")
  (princ (substr json-body 1 300))

  (setq response (http-post "http://localhost:8000/route_multi" json-body))

  (if (null response)
    (progn
      (princ "\n[ERROR] No response from backend. Is the FastAPI server running?")
      (princ "\n        Start it with:  uvicorn main:app --reload --port 8000")
      (exit)))

  (princ "\n[SPRINKLER] Response received from backend.")

  (setq all-segs (parse-segments response))
  (if (null all-segs)
    (progn (princ "\n[ERROR] Could not parse segments from response.") (exit)))

  (draw-routing all-segs "ROUTING_PIPE")

  (princ "\n\n╔══════════════════════════════════════════╗")
  (princ "\n║   SPRINKLER ROUTING COMPLETE!            ║")
  (princ (strcat "\n║   Rooms routed    : " (itoa routed-count)))
  (princ (strcat "\n║   Segments drawn  : " (itoa (length all-segs))))
  (princ "\n╚══════════════════════════════════════════╝")
  (princ)
)

;; ─── Load confirmation ────────────────────────────────────────────────────────
(princ "\n[SPRINKLER_ROUTE v2.1] Plugin loaded successfully.")
(princ "\n  Usage: Type SPRINKLER_ROUTE at the ZWCAD command prompt.")
(princ "\n  Flow : outer rect -> sprinkler layer -> inside-box layer")
(princ "\n  NEW  : each sprinkler is assigned to the polyline that")
(princ "\n         geometrically contains it (point-in-polygon).")
(princ)
