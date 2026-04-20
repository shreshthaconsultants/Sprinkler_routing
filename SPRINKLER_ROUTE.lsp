;; =============================================================================
;;  SPRINKLER_ROUTE.lsp
;;  AutoLISP plugin for ZWCAD — Automatic Sprinkler Pipe Routing
;;  Backend : FastAPI  http://localhost:8000/route
;;  Author  : Generated for ZWCAD
;; =============================================================================

;; ─── Utility: Ensure a layer exists ─────────────────────────────────────────
(defun ensure-layer (layer-name color / )
  (if (not (tblsearch "LAYER" layer-name))
    (command "._LAYER" "N" layer-name "C" (itoa color) layer-name "")
    (command "._LAYER" "C" (itoa color) layer-name "")
  )
)

;; ─── Utility: Get polyline vertices ──────────────────────────────────────────
(defun get-pline-vertices (ename / en pt-list i code dxf-data)
  (setq en (entget ename))
  (setq pt-list '())
  ;; Walk the entity's association list for group code 10 (vertex coords)
  (foreach pair en
    (if (= (car pair) 10)
      (setq pt-list (append pt-list (list (cdr pair))))
    )
  )
  pt-list
)

;; ─── Utility: Bounding box of a polyline ─────────────────────────────────────
(defun pline-bbox (ename / verts xs ys)
  (setq verts (get-pline-vertices ename))
  (if (null verts)
    nil
    (progn
      (setq xs (mapcar 'car  verts))
      (setq ys (mapcar 'cadr verts))
      (list
        (apply 'min xs)   ; xmin
        (apply 'min ys)   ; ymin
        (apply 'max xs)   ; xmax
        (apply 'max ys)   ; ymax
      )
    )
  )
)

;; ─── Utility: Check point strictly inside rectangle ──────────────────────────
(defun pt-inside-rect (px py xmin ymin xmax ymax / tol)
  (setq tol 1e-6)
  (and (> px (- xmin tol))
       (< px (+ xmax tol))
       (> py (- ymin tol))
       (< py (+ ymax tol)))
)

;; ─── Utility: Number to string (handles reals & integers) ─────────────────────
(defun num->str (n)
  (if (= (type n) 'REAL)
    (rtos n 2 6)
    (itoa n)
  )
)

;; ─── Utility: Build JSON point entry ─────────────────────────────────────────
(defun json-point (px py)
  (strcat "{\"x\":" (num->str px) ",\"y\":" (num->str py) "}")
)

;; ─── Build JSON POST body ─────────────────────────────────────────────────────
(defun build-json-body (xmin ymin xmax ymax pt-list / body i pt sep)
  (setq body
    (strcat
      "{"
      "\"xmin\":" (num->str xmin) ","
      "\"ymin\":" (num->str ymin) ","
      "\"xmax\":" (num->str xmax) ","
      "\"ymax\":" (num->str ymax) ","
      "\"points\":["
    )
  )
  (setq i 0)
  (foreach pt pt-list
    (if (> i 0) (setq body (strcat body ",")))
    (setq body (strcat body (json-point (car pt) (cadr pt))))
    (setq i (1+ i))
  )
  (setq body (strcat body "]}"))
  body
)

;; ─── HTTP POST via temp file + curl ──────────────────────────────────────────
;;  ZWCAD/AutoLISP does not have native HTTP; we shell out to curl.
;;  curl must be installed (Windows 10+: built-in; older: add curl to PATH).
(defun http-post (url json-body / tmp-in tmp-out cmd result)
  (setq tmp-in  (strcat (getenv "TEMP") "\\spr_req.json"))
  (setq tmp-out (strcat (getenv "TEMP") "\\spr_res.json"))

  ;; Write request body to temp file
  (setq fh (open tmp-in "w"))
  (write-line json-body fh)
  (close fh)

  ;; Build curl command
  (setq cmd
    (strcat
      "curl -s -X POST "
      "-H \"Content-Type: application/json\" "
      "-d @\"" tmp-in "\" "
      "\"" url "\" "
      "-o \"" tmp-out "\""
    )
  )

  ;; Execute (shell)
  (command "._SHELL" cmd)
  ;; Small pause for curl to finish
  (command "._DELAY" "2000")

  ;; Read response
  (if (findfile tmp-out)
    (progn
      (setq fh (open tmp-out "r"))
      (setq result "")
      (setq line (read-line fh))
      (while line
        (setq result (strcat result line))
        (setq line (read-line fh))
      )
      (close fh)
      result
    )
    nil
  )
)

;; ─── Minimal JSON parser: extract "segments" array ───────────────────────────
;;  We parse the raw string manually (no JSON lib in LISP).
;;  Expected pattern per segment:
;;    {"start":{"x":N,"y":N},"end":{"x":N,"y":N}}

(defun extract-number-after (key str / pos val-start val-end val-str)
  ;; Find key like "\"x\":" then read numeric value
  (setq pos (vl-string-search key str))
  (if pos
    (progn
      (setq val-start (+ pos (strlen key)))
      ;; scan forward for end of number (comma, } or whitespace)
      (setq val-end val-start)
      (while (and (< val-end (strlen str))
                  (not (member (substr str (1+ val-end) 1) '("," "}" " " "]"))))
        (setq val-end (1+ val-end))
      )
      (atof (substr str (1+ val-start) (- val-end val-start)))
    )
    nil
  )
)

(defun parse-segments (json-str / seg-list pos end-pos seg-str sx sy ex ey)
  ;; Find each occurrence of {"start": by scanning
  (setq seg-list '())
  (setq pos 0)
  (while (setq pos (vl-string-search "\"start\"" json-str pos))
    ;; Find the closing brace of this segment object
    ;; We grab a substring large enough to hold one segment
    (setq seg-str (substr json-str (1+ pos) 120))

    ;; Extract start x, y
    (setq sx (extract-number-after "\"x\":" seg-str))
    ;; For start y: find second "y":
    (setq tmp-pos (vl-string-search "\"y\":" seg-str 0))
    (if tmp-pos
      (setq sy (atof (substr seg-str (+ tmp-pos 5) 20)))
    )

    ;; Extract end x, y — search after "end":
    (setq end-pos (vl-string-search "\"end\"" seg-str 0))
    (if end-pos
      (progn
        (setq end-str (substr seg-str (1+ end-pos) 80))
        (setq ex (extract-number-after "\"x\":" end-str))
        (setq tmp2 (vl-string-search "\"y\":" end-str 0))
        (if tmp2
          (setq ey (atof (substr end-str (+ tmp2 5) 20)))
        )
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
(defun draw-routing (segments layer-name / seg)
  (ensure-layer layer-name 1)   ; color 1 = red
  (setq prev-layer (getvar "CLAYER"))
  (setvar "CLAYER" layer-name)

  (foreach seg segments
    (command "._LINE"
      (list (nth 0 seg) (nth 1 seg) 0.0)
      (list (nth 2 seg) (nth 3 seg) 0.0)
      ""
    )
  )

  (setvar "CLAYER" prev-layer)
  (princ (strcat "\n[SPRINKLER] Drew " (itoa (length segments)) " pipe segments on layer " layer-name "."))
)

;; ─── Collect INSERT blocks on a given layer inside rectangle ─────────────────
(defun collect-sprinkler-points (layer-name xmin ymin xmax ymax / ss i ent ed pt px py result)
  (setq result '())
  ;; Select all INSERT entities on the given layer
  (setq ss (ssget "X" (list (cons 0 "INSERT") (cons 8 layer-name))))

  (if (null ss)
    (progn
      (princ (strcat "\n[SPRINKLER] No INSERT blocks found on layer: " layer-name))
      result
    )
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq ent (ssname ss i))
        (setq ed  (entget ent))
        (setq pt  (cdr (assoc 10 ed)))   ; insertion point
        (setq px  (car  pt))
        (setq py  (cadr pt))
        (if (pt-inside-rect px py xmin ymin xmax ymax)
          (setq result (append result (list (list px py))))
        )
        (setq i (1+ i))
      )
      (princ (strcat "\n[SPRINKLER] Found " (itoa (length result)) " sprinkler(s) inside rectangle."))
      result
    )
  )
)

;; ─── MAIN COMMAND: SPRINKLER_ROUTE ───────────────────────────────────────────
(defun C:SPRINKLER_ROUTE ( / sel-ent bbox xmin ymin xmax ymax layer-name pts json-body response segs)

  (princ "\n╔══════════════════════════════════════════╗")
  (princ "\n║      SPRINKLER AUTO ROUTING v1.0         ║")
  (princ "\n╚══════════════════════════════════════════╝")
  (princ "\n")

  ;; ── Step 1: Select rectangle (closed polyline) ───────────────────────────
  (princ "\n[1/4] Select the room rectangle (closed polyline): ")
  (setq sel-ent (car (entsel "\nClick on the boundary rectangle: ")))

  (if (null sel-ent)
    (progn (princ "\n[ERROR] No entity selected. Aborting.") (exit))
  )

  ;; Verify it's a LWPOLYLINE or POLYLINE
  (setq ent-type (cdr (assoc 0 (entget sel-ent))))
  (if (not (or (= ent-type "LWPOLYLINE") (= ent-type "POLYLINE")))
    (progn (princ "\n[ERROR] Selected entity is not a polyline. Aborting.") (exit))
  )

  ;; Get bounding box
  (setq bbox (pline-bbox sel-ent))
  (if (null bbox)
    (progn (princ "\n[ERROR] Could not read polyline vertices. Aborting.") (exit))
  )

  (setq xmin (nth 0 bbox))
  (setq ymin (nth 1 bbox))
  (setq xmax (nth 2 bbox))
  (setq ymax (nth 3 bbox))

  (princ (strcat "\n[SPRINKLER] Rectangle: xmin=" (num->str xmin)
                 " ymin=" (num->str ymin)
                 " xmax=" (num->str xmax)
                 " ymax=" (num->str ymax)))

  ;; ── Step 2: Ask for sprinkler block layer ────────────────────────────────
  (princ "\n[2/4] Enter the sprinkler block layer name: ")
  (setq layer-name (getstring "\nSprinkler layer name: "))

  (if (or (null layer-name) (= layer-name ""))
    (progn (princ "\n[ERROR] Layer name cannot be empty. Aborting.") (exit))
  )

  ;; ── Step 3: Collect sprinkler insert points ──────────────────────────────
  (princ "\n[3/4] Scanning drawing for sprinkler blocks...")
  (setq pts (collect-sprinkler-points layer-name xmin ymin xmax ymax))

  (if (null pts)
    (progn (princ "\n[ERROR] No sprinkler points found inside rectangle. Aborting.") (exit))
  )

  ;; ── Step 4: Send to FastAPI backend ──────────────────────────────────────
  (princ "\n[4/4] Sending data to routing backend (http://localhost:8000/route)...")
  (setq json-body (build-json-body xmin ymin xmax ymax pts))

  ;; Debug: show JSON body
  (princ "\n[DEBUG] JSON body (first 200 chars): ")
  (princ (substr json-body 1 200))

  (setq response (http-post "http://localhost:8000/route" json-body))

  (if (null response)
    (progn
      (princ "\n[ERROR] No response from backend. Is the FastAPI server running?")
      (princ "\n        Start it with:  uvicorn main:app --reload --port 8000")
      (exit)
    )
  )

  (princ "\n[SPRINKLER] Response received from backend.")

  ;; ── Step 5: Parse segments & draw ────────────────────────────────────────
  (setq segs (parse-segments response))

  (if (null segs)
    (progn (princ "\n[ERROR] Could not parse routing segments from response.") (exit))
  )

  (draw-routing segs "ROUTING_PIPE")

  (princ "\n╔══════════════════════════════════════════╗")
  (princ "\n║  SPRINKLER ROUTING COMPLETE!             ║")
  (princ (strcat "\n║  Total pipe segments drawn: " (itoa (length segs))))
  (princ "\n╚══════════════════════════════════════════╝")
  (princ)
)

;; ─── Load confirmation ────────────────────────────────────────────────────────
(princ "\n[SPRINKLER_ROUTE] Plugin loaded successfully.")
(princ "\n  Usage: Type SPRINKLER_ROUTE at the ZWCAD command prompt.")
(princ)
