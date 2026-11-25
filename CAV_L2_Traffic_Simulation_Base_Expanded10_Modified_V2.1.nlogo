;; ==============================================================
;; ITSoS BASE MODEL + RAMP METERING CS (Expanded10)
;; Builds on Expanded9. Changes in this pass are marked >>> E10:
;;   1. input-flow-pct is now THE flow-rate knob: % of all-HV lane
;;      saturation flow. arrival-rate is gone.
;;   2. Per-lane spawning, so demand can actually reach capacity.
;;      Entries denied because the lane entrance is occupied are
;;      counted in blocked-count (a congestion signal).
;;   3. Per-vehicle desired speed (my-base-speed), so faster vehicles
;;      catch slower ones and flow affects travel time.
;;   4. HV random slowdown (Nagel-Schreckenberg style), controlled by
;;      hv-slowdown-prob. CAVs don't randomly brake.
;;   5. Seed: seed = 0 picks a fresh seed, and the seed is logged.
;;   6. One CSV per run, named by its parameters (safe for
;;      BehaviorSpace with multiple threads; no repeated headers).
;;   7. Queued ramp vehicles are hidden until released.
;; ==============================================================
extensions [csv]

breed [vehicles vehicle]

vehicles-own [
  is-cav?
  speed
  desired-speed
  my-base-speed      ;; >>> E10: this vehicle's own free-flow speed
  perceived-weather
  entry-tick
  ramp-agent-state
  headway            ;; desired time gap (ticks) to leader
  road-tick
]

patches-own [
  zone-id
  weather-severity
  rwis-station?
  is-ramp?
]

globals [
  zone-length
  travel-times-cav
  travel-times-hv
  signal-phase
  metering-rate
  mainline-density
  ramp-queue-length
  phase-timer
  run-label
  output-file-name
  entered-count
  exited-count
  sum-travel-time
  sum-travel-time-count
  tick-seconds
  results
  saturation-flow    ;; >>> E10: all-HV lane capacity, veh/tick/lane
  blocked-count      ;; >>> E10: mainline arrivals denied at entrance
  entry-queues
  sum-wait
  sum-road
]
;; NOTE: seed, input-flow-pct and hv-slowdown-prob are Interface
;; widgets, so they must NOT appear in the globals list above.

;; ------------------------------------------------------------
;; SETUP
;; ------------------------------------------------------------
to setup
  clear-all
  file-close-all

  ;; >>> E10: seed = 0 means "pick one for me"; either way it's logged
  if seed = 0 [ set seed new-seed ]
  random-seed seed

  resize-world 0 road-length -2 2
  set-patch-size max (list 1 (600 / (road-length + 1)))

  set travel-times-cav []
  set travel-times-hv []
  set tick-seconds 1
  set entered-count 0
  set exited-count 0
  set sum-travel-time 0
  set sum-travel-time-count 0
  set blocked-count 0
  if not is-list? results [ set results [] ]

  ;; >>> E10: steady-state following under safe-speed = gap / headway
  ;; gives spacing = v*h + 1 patches, so lane capacity = v / (v*h + 1).
  ;; Fixed to the ALL-HV value so the same input-flow-pct means the
  ;; same demand at every cav-fraction (otherwise MPR and demand would
  ;; change together). Replace with a measured value if you calibrate.
  set saturation-flow base-desired-speed / (base-desired-speed * hv-headway + 1)

  setup-road
  setup-weather-zones
  setup-ramp
  set entry-queues [[] [] []]
  set sum-wait 0
  set sum-road 0
  set saturation-flow 0.39   ;; measured all-HV capacity (Case A at 150%)This doesn't bias the MPR comparison. Every MPR still gets the same demand at each input-flow-pct, because saturation-flow is one fixed number used by every case. Calibrating only moves where 100% falls on the flow scale.

  ;; >>> E10: one file per run, named by its parameters
;  set output-file-name (word "ITS_rwis-" with-rwis?
;                             "_cav-" cav-fraction
;                             "_flow-" input-flow-pct
;                             "_ramp-" ramp-arrival-rate
;                             "_seed-" seed ".csv")
;  if file-exists? output-file-name [ file-delete output-file-name ]
;  file-open output-file-name
;  file-print "ticks,seed,with_rwis,cav_fraction,input_flow_pct,input_flow_veh_h,ramp_arrival_rate,avg_speed_cav,avg_speed_hv,mean_tt_cav,mean_tt_hv,avg_tt,blocked_count,ramp_queue_length,metering_rate,mainline_density"

  reset-ticks
end

to setup-road
  ask patches [
    set pcolor gray - 2
    set zone-id 0
    set weather-severity 0
    set rwis-station? false
    set is-ramp? false
  ]
end

to setup-weather-zones
  set zone-length max (list 1 (ceiling ((road-length + 1) / num-zones)))
  ask patches [
    set zone-id floor (pxcor / zone-length)
    recolor-patch
  ]
  let z 0
  while [z < num-zones] [
    let mid-x (z * zone-length) + floor (zone-length / 2)
    ask patches with [pxcor = mid-x and pycor = 2] [
      set rwis-station? true
      set pcolor blue
    ]
    set z z + 1
  ]
end

to setup-ramp
  ifelse is-number? ramp-position
  [ ]
  [ set ramp-position floor (road-length / 2) ]
  ask patches with [pxcor = ramp-position and pycor = -2] [
    set is-ramp? true
    set pcolor violet
  ]
  set signal-phase "red"
  set metering-rate 0
  set mainline-density 0
  set ramp-queue-length 0
  set phase-timer 0
end

;; ------------------------------------------------------------
;; GO
;; ------------------------------------------------------------
to go
  update-weather
  spawn-vehicles
  spawn-ramp-vehicles
  update-ramp-meter
  release-from-ramp-queue


;  ask vehicles [
;    sense-weather
;    update-desired-speed
;    move-vehicle
;  ]
  foreach sort-on [(- xcor)] vehicles with [ramp-agent-state != "queued"] [ v ->
  ask v [
    sense-weather
    update-desired-speed
    move-vehicle
  ]
]


  remove-exited-vehicles
  tick
  do-plots
  ;populate-file
  if ticks mod 1800 = 0 [ print-summary ]
  if ticks >= 18000 [
    file-close
    stop
  ]
end

to go-n [n]
  repeat n [ go ]
end

to do-plots
  set-current-plot "Avg Speed by Type"
  create-temporary-plot-pen "cav"
  set-plot-pen-color blue
  plot avg-speed-cav
  create-temporary-plot-pen "hv"
  set-plot-pen-color red
  plot avg-speed-hv

  set-current-plot "Avg Travel Time"
  create-temporary-plot-pen "cav"
  set-plot-pen-color blue
  plot mean-tt-cav
  create-temporary-plot-pen "hv"
  set-plot-pen-color red
  plot mean-tt-hv

  set-current-plot "Ramp Queue Length"
  create-temporary-plot-pen "queue"
  set-plot-pen-color violet
  plot ramp-queue-length

  set-current-plot "Ramp Metering Rate"
  create-temporary-plot-pen "rate"
  set-plot-pen-color green
  plot metering-rate
end

;; ------------------------------------------------------------
;; WEATHER
;; ------------------------------------------------------------
to update-weather
  let zones (range num-zones)
  foreach zones [ z ->
    if random-float 1 < weather-change-prob [
      let delta (one-of (list -1 1))
      ask patches with [zone-id = z and pycor != 2] [
        set weather-severity clamp01to3 (weather-severity + delta)
        recolor-patch
      ]
    ]
  ]
end

to-report clamp01to3 [x]
  report max (list 0 (min (list 3 x)))
end

to recolor-patch
  if not rwis-station? and not is-ramp? [
    if weather-severity = 0 [ set pcolor gray - 2 ]
    if weather-severity = 1 [ set pcolor yellow - 2 ]
    if weather-severity = 2 [ set pcolor orange ]
    if weather-severity = 3 [ set pcolor red ]
  ]
end

;; Three-way perception:
;;  1. CAV + with-rwis? -> zone-based V2I lookahead
;;  2. CAV, no RWIS     -> onboard sensors, cav-perception-patches
;;  3. HV               -> hv-perception-patches
to sense-weather
  ifelse (is-cav? and with-rwis?) [
    let my-zone [zone-id] of patch-here
    let max-zone (my-zone + comm-range-zones)
    let visible patches with [zone-id >= my-zone and zone-id <= max-zone]
    set perceived-weather max [weather-severity] of visible
  ] [
    let rangedata ifelse-value is-cav? [cav-perception-patches] [hv-perception-patches]
    let near-patches patches with [
      pycor = [pycor] of myself and
      pxcor >= [pxcor] of myself and
      pxcor <= ([pxcor] of myself + rangedata)
    ]
    ifelse any? near-patches
    [ set perceived-weather max [weather-severity] of near-patches ]
    [ set perceived-weather [weather-severity] of patch-here ]
  ]
end

;; ------------------------------------------------------------
;; VEHICLE BEHAVIOR
;; ------------------------------------------------------------
to update-desired-speed
  let factor (1 - perceived-weather * weather-speed-penalty)
  let target (my-base-speed * factor)   ;; >>> E10: was base-desired-speed
  ifelse is-cav? [
    set desired-speed desired-speed + ((target - desired-speed) * cav-adjustment-rate)
  ] [
    set desired-speed target
  ]
end
to move-vehicle
  if ramp-agent-state = "queued" [ stop ]
  let leader min-one-of (other vehicles with [
    pycor = [pycor] of myself and xcor > [xcor] of myself
  ]) [xcor]
  let target-speed desired-speed
  let safe-speed 1000000                       ;; no leader = no limit
  if leader != nobody [
    let gap (([xcor] of leader) - xcor - 1)
    set safe-speed max (list 0 (gap / (1 + headway)))
    set target-speed min (list desired-speed safe-speed)
  ]
  ifelse speed < target-speed
  [ set speed min (list target-speed (speed + max-accel)) ]
  [ set speed max (list target-speed (speed - max-decel)) ]
  if not is-cav? and random-float 1 < hv-slowdown-prob [
    set speed speed - max-decel
  ]
  ;; hard limit: brake as hard as needed so no car overlaps its leader
  set speed max (list 0 (min (list speed safe-speed)))
  ;; exit fix: never get stuck just short of the road's end
  ifelse xcor + speed >= road-length [ set xcor road-length ] [ fd speed ]
end
to move-vehicle2
  if ramp-agent-state = "queued" [ stop ]
  let leader min-one-of (other vehicles with [
    pycor = [pycor] of myself and xcor > [xcor] of myself
  ]) [xcor]
  let target-speed desired-speed
  if leader != nobody [
    let gap (([xcor] of leader) - xcor - 1)
;    let safe-speed ifelse-value (headway > 0) [ gap / headway ] [ gap ]
    let safe-speed gap / (1 + headway)
    set safe-speed max (list 0 safe-speed)
    set target-speed min (list desired-speed safe-speed)
  ]
  ifelse speed < target-speed
  [ set speed min (list target-speed (speed + max-accel)) ]
  [ set speed max (list target-speed (speed - max-decel)) ]

  ;; >>> E10: HV random slowdown (Nagel & Schreckenberg 1992).
  ;; Creates density-dependent stop-and-go; CAVs don't do this.
  if not is-cav? and random-float 1 < hv-slowdown-prob [
    set speed speed - max-decel
  ]

  set speed max (list 0 speed)
  fd speed
end

;; >>> E10: per-vehicle free-flow speed. CAVs get a tighter spread
;; than HVs (more uniform speed control). Floor of 1 keeps every
;; vehicle moving.
to-report draw-base-speed [cav?]
  let sd ifelse-value cav? [0.05] [0.10]
  report max (list 1 (base-desired-speed * (1 + random-normal 0 sd)))
end

;; ------------------------------------------------------------
;; SPAWNING
;; ------------------------------------------------------------
;; >>> E10: one arrival draw per lane per tick, probability set by
;; input-flow-pct. Entrance check is per lane (was: whole column).
;; Spawn speed is capped by the safe speed behind any vehicle already
;; in the lane, so a new vehicle can't enter faster than it can stop.
to spawn-vehicles2
  foreach [-1 0 1] [ lane ->
    if random-float 1 < lane-arrival-prob [
      ifelse not any? vehicles with [ycor = lane and xcor < 1] [
        create-vehicles 1 [
          setxy 0 lane
          set heading 90
          set is-cav? (random-float 1 < cav-fraction)
          set headway ifelse-value is-cav? [cav-headway] [hv-headway]
          set my-base-speed draw-base-speed is-cav?
          set desired-speed my-base-speed
          set speed my-base-speed
          let lead min-one-of (other vehicles with [ycor = lane]) [xcor]
          if lead != nobody [
            let gap ([xcor] of lead) - xcor - 1
            set speed max (list 0 (min (list speed (gap / headway))))
          ]
          set entry-tick ticks
          set shape "car"
          set color ifelse-value is-cav? [blue] [white]
          set ramp-agent-state "n/a"
        ]
        set entered-count entered-count + 1
      ] [
        set blocked-count blocked-count + 1
      ]
    ]
  ]
end
to spawn-vehicles3
  foreach [0 1 2] [ i ->
    let lane item i [-1 0 1]
    let q item i entry-queues
    if random-float 1 < lane-arrival-prob [ set q lput ticks q ]
    if not empty? q and not any? vehicles with [ycor = lane and xcor < 1] [
      let arrived first q
      set q but-first q
      create-vehicles 1 [
        setxy 0 lane
        set heading 90
        set is-cav? (random-float 1 < cav-fraction)
        set headway ifelse-value is-cav? [cav-headway] [hv-headway]
        set my-base-speed draw-base-speed is-cav?
        set desired-speed my-base-speed
        set speed my-base-speed
        let lead min-one-of (other vehicles with [ycor = lane]) [xcor]
        if lead != nobody [
          set speed max (list 0 (min (list speed ((([xcor] of lead) - xcor - 1) / headway))))
        ]
        set entry-tick arrived          ;; waiting time now counts in ATT
        set shape "car"
        set color ifelse-value is-cav? [blue] [white]
        set ramp-agent-state "n/a"
      ]
      set entered-count entered-count + 1
    ]
    set entry-queues replace-item i entry-queues q
  ]
  set blocked-count sum map length entry-queues
end
to spawn-vehicles
  foreach [0 1 2] [ i ->
    let lane item i [-1 0 1]
    let q item i entry-queues
    if random-float 1 < lane-arrival-prob [
      let new-cav? (random-float 1 < cav-fraction)
      set q lput (list ticks new-cav? (draw-base-speed new-cav?)) q
    ]
    let entering true
    while [entering and not empty? q] [
      let nxt first q
      let v item 2 nxt
      let h ifelse-value (item 1 nxt) [cav-headway] [hv-headway]
      let lead min-one-of (vehicles with [ycor = lane]) [xcor]
      let x0 ifelse-value (lead = nobody) [v] [min (list v (([xcor] of lead) - (v * h + 1)))]
      ifelse x0 >= 0 [
        set q but-first q
        create-vehicles 1 [
          setxy x0 lane
          set heading 90
          set is-cav? item 1 nxt
          set headway h
          set my-base-speed v
          set desired-speed v
          set speed v
          set entry-tick item 0 nxt
          set shape "car"
          set color ifelse-value is-cav? [blue] [white]
          set ramp-agent-state "n/a"
          set road-tick ticks
        ]
        set entered-count entered-count + 1
      ] [ set entering false ]
    ]
    set entry-queues replace-item i entry-queues q
  ]
  set blocked-count sum map length entry-queues
end
to spawn-ramp-vehicles
  if random-float 1 < ramp-arrival-rate [
    create-vehicles 1 [
      setxy ramp-position -2
      set heading 90
      set is-cav? (random-float 1 < cav-fraction)
      set headway ifelse-value is-cav? [cav-headway] [hv-headway]
      set my-base-speed draw-base-speed is-cav?   ;; >>> E10
      set desired-speed my-base-speed
      set speed 0
      set entry-tick ticks
      set shape "car"
      set color ifelse-value is-cav? [blue] [white]
      set ramp-agent-state "queued"
      set hidden? true                            ;; >>> E10
    ]
    set entered-count entered-count + 1
  ]
end

;; ------------------------------------------------------------
;; RAMP METER
;; ------------------------------------------------------------
to update-ramp-meter
  let nearby-mainline patches with [
    pycor != -2 and pycor != 2 and
    pxcor >= (ramp-position - detection-range) and
    pxcor <= (ramp-position + detection-range)
  ]
  ifelse any? nearby-mainline
  [ set mainline-density (count vehicles-on nearby-mainline) / (count nearby-mainline) ]
  [ set mainline-density 0 ]

  set ramp-queue-length count vehicles with [ramp-agent-state = "queued"]

  ifelse ramp-queue-length > queue-threshold [
    set signal-phase "green"
    set phase-timer green-duration-ticks
  ] [
    ifelse phase-timer > 0 [
      set phase-timer phase-timer - 1
    ] [
      ifelse signal-phase = "green" [
        set signal-phase "red"
        set phase-timer red-duration-ticks
      ] [
        set signal-phase "green"
        set phase-timer green-duration-ticks
      ]
    ]
  ]
  set metering-rate 60 / max (list 1 (green-duration-ticks + red-duration-ticks))
end

to-report red-duration-ticks
  let density-cap 1.0
  let scaled min (list 1 (mainline-density / density-cap))
  report round (min-red-ticks + scaled * (max-red-ticks - min-red-ticks))
end

to release-from-ramp-queue
  if signal-phase != "green" [ stop ]
  let candidate min-one-of (vehicles with [ramp-agent-state = "queued"]) [entry-tick]
  if candidate = nobody [ stop ]
  let chosen-lane nobody
  foreach [-1 0 1] [ lane ->
    if chosen-lane = nobody [
      let blockers vehicles with [
        pycor = lane and
        xcor >= (ramp-position - 1) and xcor <= (ramp-position + merge-gap-needed)
      ]
      if not any? blockers [ set chosen-lane lane ]
    ]
  ]
  if chosen-lane != nobody [
    ask candidate [
      set hidden? false
      setxy ramp-position chosen-lane
      set ramp-agent-state "on-road"
      set speed min (list desired-speed merge-speed-limit)
      set road-tick ticks
    ]
  ]
end

to remove-exited-vehicles
  ask vehicles with [xcor >= road-length] [
    let tt (ticks - entry-tick)
    ifelse is-cav?
    [ set travel-times-cav lput tt travel-times-cav ]
    [ set travel-times-hv lput tt travel-times-hv ]
    set sum-travel-time sum-travel-time + tt
    set sum-travel-time-count sum-travel-time-count + 1
    set exited-count exited-count + 1
    set sum-wait sum-wait + (road-tick - entry-tick)
    set sum-road sum-road + (ticks - road-tick)
    die
  ]
end

;; ------------------------------------------------------------
;; REPORTERS
;; ------------------------------------------------------------
to-report avg-speed-cav
  report ifelse-value any? vehicles with [is-cav?]
  [ mean [speed] of vehicles with [is-cav?] ] [0]
end

to-report avg-speed-hv
  report ifelse-value any? vehicles with [not is-cav?]
  [ mean [speed] of vehicles with [not is-cav?] ] [0]
end

to-report mean-tt-cav
  report ifelse-value (not empty? travel-times-cav) [mean travel-times-cav] [0]
end

to-report mean-tt-hv
  report ifelse-value (not empty? travel-times-hv) [mean travel-times-hv] [0]
end

;; >>> flow-rate reporters
;; Per-lane, per-tick arrival probability from input-flow-pct.
to-report lane-arrival-prob
  report min (list 1 (input-flow-pct / 100 * saturation-flow))
end

;; All-HV lane capacity in veh/h/lane (assumes tick-seconds = 1).
to-report saturation-flow-veh-h
  report saturation-flow * 3600 / tick-seconds
end

;; Total offered demand, mainline (3 lanes) + ramp, veh/h.
to-report input-flow-veh-h
  report (3 * lane-arrival-prob + ramp-arrival-rate) * 3600 / tick-seconds
end

;; Mean completed-trip travel time in ticks, CAV+HV combined.
;; "per-km" stays provisional until patches are calibrated to km.
to-report avg-travel-time-per-km
  report ifelse-value sum-travel-time-count > 0
  [ sum-travel-time / sum-travel-time-count ]
  [ 0 ]
end

;; Qr/Qi: served flow over offered flow.
to-report actual-road-capacity
  let elapsed-hours (ticks * tick-seconds) / 3600
  ifelse elapsed-hours > 0 and input-flow-veh-h > 0
  [ report (exited-count / elapsed-hours) / input-flow-veh-h ]
  [ report 0 ]
end

;; ------------------------------------------------------------
;; OUTPUT
;; ------------------------------------------------------------
;; >>> column order matches the header written in setup.
to populate-file
  file-print (word
    ticks ","
    seed ","
    with-rwis? ","
    cav-fraction ","
    input-flow-pct ","
    input-flow-veh-h ","
    ramp-arrival-rate ","
    avg-speed-cav ","
    avg-speed-hv ","
    mean-tt-cav ","
    mean-tt-hv ","
    avg-travel-time-per-km ","
    blocked-count ","
    ramp-queue-length ","
    metering-rate ","
    mainline-density
  )
  file-flush
end

to record-scene
  let row (list ticks seed with-rwis? cav-fraction input-flow-pct ramp-arrival-rate
    avg-speed-cav avg-speed-hv
    mean-tt-cav mean-tt-hv
    blocked-count ramp-queue-length metering-rate mainline-density
    avg-travel-time-per-km actual-road-capacity)
  set results lput row results
  output-print (word
    "RWIS=" with-rwis?
    " CAV%=" (precision (cav-fraction * 100) 0)
    " flow%=" input-flow-pct
    " ramp-rate=" ramp-arrival-rate
    " -> speed(cav/hv)=" (precision avg-speed-cav 2) "/" (precision avg-speed-hv 2)
    " tt(cav/hv)=" (precision mean-tt-cav 2) "/" (precision mean-tt-hv 2)
    " blocked=" blocked-count
    " queue=" ramp-queue-length
    " meter-rate=" (precision metering-rate 2)
    " density=" (precision mainline-density 3)
    " avgTT=" (precision avg-travel-time-per-km 2)
    " capacity=" (precision actual-road-capacity 3)
    " (seed=" seed " ticks=" ticks ")")
end
to print-summary
  print (word "tick " ticks
    " | seed " seed
    " | CAV% " (precision (cav-fraction * 100) 0)
    " | flow% " input-flow-pct
    " | ATT " (precision avg-travel-time-per-km 2) " ticks"
    " | ATT cav/hv " (precision mean-tt-cav 2) "/" (precision mean-tt-hv 2)
    " | capacity (Qr/Qi) " (precision actual-road-capacity 3)
    " | served " (precision served-flow-veh-h 0) " veh/h"
    " | wait " (precision (sum-wait / max (list 1 exited-count)) 1)
    " | on-road " (precision (sum-road / max (list 1 exited-count)) 1)
    " | entry-q " blocked-count
    " | ramp-q " ramp-queue-length
    " | stopped " count vehicles with [speed = 0 and ramp-agent-state != "queued"]
  )

end

to-report served-flow-veh-h
  let elapsed-hours (ticks * tick-seconds) / 3600
  report ifelse-value elapsed-hours > 0 [ exited-count / elapsed-hours ] [ 0 ]
end

to clear-results
  set results []
  clear-output
end

;; ------------------------------------------------------------
;; INTERFACES
;; ------------------------------------------------------------
;; REMOVE: [slider] arrival-rate   (nothing reads it any more)
;;
;; ADD / KEEP:
;;  [input]  seed              Number, default 1 (0 = random, logged)
;;  [slider] input-flow-pct    10 .. 150, step 10, default 60
;;           (% of all-HV lane saturation flow; 100 = at capacity)
;;  [slider] hv-slowdown-prob  0 .. 0.3, step 0.01, default 0.1
;;  [monitor] saturation-flow-veh-h
;;  [monitor] input-flow-veh-h
;;  [monitor] blocked-count
;;
;; All other widgets unchanged from Expanded9 (cav-headway,
;; hv-headway, cav-perception-patches, ramp-meter sliders, etc.).
;;
;; Removed dead code: setup-output-file, log-performance-data and
;; close-output-file were never called. If a button still points at
;; one of them, delete that button.
;;
;; ------------------------------------------------------------
;; FIRST BEHAVIORSPACE SWEEP (flow effect alone)
;; ------------------------------------------------------------
;;  ["input-flow-pct" 20 40 60 80 100 120]
;;  ["cav-fraction" 0 0.25 0.5 0.75 1]
;;  ["seed" 1 2 3 4 5 6 7 8 9 10]
;;  ["with-rwis?" false]   ["ramp-arrival-rate" 0]
;;  ["weather-change-prob" 0]
;; Expect: flat ATT at low flow%, sharp rise near 100%, blocked-count
;; climbing at the same point; the rise shifts right as cav-fraction
;; increases.
;;
;; CALIBRATION CHECK: all-HV, weather off, ramp off, input-flow-pct
;; 150. Measure steady throughput (exited per tick after warm-up / 3).
;; Random slowdowns and speed spread make the real capacity lower
;; than the formula; if it's well below saturation-flow, set
;; saturation-flow in setup to the measured value so 100% really
;; means saturated.
@#$#@#$#@
GRAPHICS-WINDOW
376
18
984
38
-1
-1
2.3904382470119523
1
10
1
1
1
0
1
1
1
0
250
-2
2
0
0
1
ticks
30.0

BUTTON
0
10
63
43
setup
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
63
10
126
43
GO
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SWITCH
183
102
296
135
with-rwis?
with-rwis?
0
1
-1000

SLIDER
6
176
178
209
road-length
road-length
10
500
250.0
10
1
NIL
HORIZONTAL

SLIDER
6
208
178
241
num-zones
num-zones
2
10
5.0
1
1
NIL
HORIZONTAL

SLIDER
6
273
178
306
cav-fraction
cav-fraction
0
1
1.0
0.05
1
NIL
HORIZONTAL

SLIDER
6
338
178
371
comm-range-zones
comm-range-zones
0
5
2.0
1
1
NIL
HORIZONTAL

SLIDER
11
77
188
110
hv-perception-patches
hv-perception-patches
1
20
3.0
1
1
NIL
HORIZONTAL

SLIDER
183
199
355
232
weather-change-prob
weather-change-prob
0
1
0.6
0.01
1
NIL
HORIZONTAL

SLIDER
185
235
366
268
weather-speed-penalty
weather-speed-penalty
0.0
0.5
0.16
0.01
1
NIL
HORIZONTAL

SLIDER
6
373
178
406
cav-adjustment-rate
cav-adjustment-rate
0
1
0.15
0.01
1
NIL
HORIZONTAL

SLIDER
7
407
179
440
base-desired-speed
base-desired-speed
0
40
6.0
1
1
NIL
HORIZONTAL

SLIDER
6
437
178
470
max-accel
max-accel
0.05
2
0.4
0.05
1
NIL
HORIZONTAL

SLIDER
8
472
180
505
max-decel
max-decel
0.05
3
0.8
0.05
1
NIL
HORIZONTAL

SLIDER
7
304
179
337
input-flow-pct
input-flow-pct
10
180
160.0
10
1
NIL
HORIZONTAL

PLOT
366
173
688
520
Avg Speed by Type
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"cav" 1.0 0 -16777216 true "" "avg-speed-cav"
"hv" 1.0 0 -2139308 true "" "avg-speed-hv"

PLOT
721
173
1045
469
Avg Travel Time
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"cav" 1.0 0 -16777216 true "" "mean-tt-cav"
"hv" 1.0 0 -7500403 true "" "mean-tt-hv"

SLIDER
6
241
178
274
num-vehicles
num-vehicles
10
300
300.0
10
1
NIL
HORIZONTAL

SLIDER
184
282
356
315
ramp-arrival-rate
ramp-arrival-rate
0
0.3
0.2
0.05
1
NIL
HORIZONTAL

SLIDER
181
316
353
349
ramp-position
ramp-position
0
road-length
10.0
road-length / 2
1
NIL
HORIZONTAL

SLIDER
181
349
353
382
detection-range
detection-range
0
road-length
2.0
road-length / 10
1
NIL
HORIZONTAL

SLIDER
182
381
354
414
queue-threshold
queue-threshold
1
30
7.0
1
1
NIL
HORIZONTAL

SLIDER
181
412
353
445
green-duration-ticks
green-duration-ticks
1
10
1.0
2
1
NIL
HORIZONTAL

SLIDER
182
448
354
481
min-red-ticks
min-red-ticks
1
20
3.0
1
1
NIL
HORIZONTAL

SLIDER
183
483
355
516
max-red-ticks
max-red-ticks
1
40
13.0
1
1
NIL
HORIZONTAL

SLIDER
184
517
356
550
merge-gap-needed
merge-gap-needed
1
10
5.0
1
1
NIL
HORIZONTAL

SLIDER
181
550
353
583
merge-speed-limit
merge-speed-limit
0
base-desired-speed
0.6
base-desired-speed / 10
1
NIL
HORIZONTAL

PLOT
1068
184
1347
397
Ramp Queue Length
ticks
ramp-queue-length
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"default" 1.0 0 -16777216 true "" ""

PLOT
1072
396
1348
626
Ramp Metering Rate
NIL
NIL
0.0
10.0
0.0
10.0
true
false
"" ""
PENS
"default" 1.0 0 -16777216 true "" ""

BUTTON
190
71
319
104
Close Output File
NIL
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SLIDER
0
509
172
542
cav-lanes
cav-lanes
0
3
0.0
1
1
NIL
HORIZONTAL

SLIDER
1087
643
1259
676
input-flow-pct
input-flow-pct
80
160
160.0
1
1
NIL
HORIZONTAL

MONITOR
194
147
363
192
Average travel time (s/km)
avg-travel-time-per-km
17
1
11

MONITOR
381
127
556
172
Actual road capacity (Qr/Qi)
actual-road-capacity
17
1
11

MONITOR
971
524
1077
569
Vehicles on road
count turtles
17
1
11

BUTTON
189
10
318
43
go-num-ticks
go-n num-ticks
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
126
10
189
43
step
go
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

INPUTBOX
307
72
378
132
num-ticks
18000.0
1
0
Number

BUTTON
130
41
193
74
stop
stop
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
192
41
255
74
reset
clear-all
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
65
42
132
75
record
record-scene
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
0
43
63
76
clear
clear-results
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SLIDER
0
109
175
142
cav-perception-patches
cav-perception-patches
1
20
6.0
1
1
NIL
HORIZONTAL

SLIDER
3
578
175
611
cav-headway
cav-headway
0.1
3
0.5
0.1
1
NIL
HORIZONTAL

SLIDER
0
543
172
576
hv-headway
hv-headway
0.5
4
2.0
0.5
1
NIL
HORIZONTAL

INPUTBOX
325
11
375
71
seed
49.0
1
0
Number

SLIDER
2
143
174
176
hv-slowdown-prob
hv-slowdown-prob
0
0.3
0.1
0.01
1
NIL
HORIZONTAL

@#$#@#$#@
## WHAT IS IT?

This is an agent-based NetLogo model of a one-way, three-lane expressway carrying a mix of human-driven vehicles (HVs) and Level 2 connected and autonomous vehicles (CAVs). It's used to study how the share of CAVs, called the market penetration rate (MPR), affects traffic efficiency at different demand levels.

The model is built around the two efficiency measures in Song et al. (2023), "Impacts of Connected and Autonomous Vehicles with Level 2 Automation on Traffic Efficiency and Energy Consumption" (*Journal of Advanced Transportation*):

- **Average travel time (ATT):** the mean time from when a vehicle arrives until it leaves the road, including any wait at the entrance.
- **Actual road capacity (Qr/Qi):** the real flow rate divided by the input flow rate.

CAVs differ from HVs in two ways. They keep a shorter time gap to the car ahead, and they never brake at random. HVs follow a Nagel–Schreckenberg-style random-slowdown rule. Demand is set as a percentage of the all-HV road capacity, so every MPR faces the same traffic and the CAV effect can be isolated.

Beyond Song's setup, the model adds three features that can each be switched on separately:

- **Changing weather by zone,** which lowers vehicle speeds.
- **Road Weather Information System (RWIS) warnings,** which let CAVs see weather further ahead.
- **An adaptive ramp meter** at an on-ramp, which responds to mainline density.

It's a simplified model that captures the mechanisms and trends Song describes, not a replica of the paper's VISSIM simulation. Distances are in patches and time in ticks (1 tick = 1 second), and patches haven't been calibrated to real distances. So the results should be compared on trends and relative change, not exact values.

The existing "What this model does" notes in your Info tab mention a 4 km road, 0.6 s / 1.2 s headways, and dedicated CAV lanes. None of those match the current code: the road is 250 patches, the headways are 0.5 and 2.0, and the `cav-lanes` slider isn't used. Update or delete those notes so the Info tab matches what the model actually does.

;## WHAT THIS MODEL DOES
;
;This model reproduces the mechanisms behind Sections 3.2.1 (Impacts on Travel Time) and 3.2.2 (Impacts on Actual Road Capacity) of:
;
;Song, H., Zhao, F., Zhu, G., & Liu, Z. (2023). "Impacts of Connected and Autonomous Vehicles with Level 2 Automation on Traffic Efficiency and Energy Consumption." Journal of Advanced Transportation, 2023, 6348778.
;
;It simulates a one-way, 3-lane, 4 km expressway section (matching the paper's VISSIM setup) with a mix of L2 CAVs (blue) and human-driven vehicles / HVs (yellow).
;
;KEY MECHANISM (matches paper section 2.2):
;- CAVs use a shorter desired time headway (0.6 s) representing the MIXIC/ACC-based car-following logic described in the paper, versus HVs (1.2 s), representing Wiedemann-99-like human following behavior.
;- CAVs may drive in any lane; if dedicated CAV lanes are set (cav-lanes slider), HVs are excluded from those lanes (rightmost lanes), matching the paper's dedicated-lane rule.
;
;KEY OUTPUTS (matches paper section 3.2.1 / 3.2.2):
;- avg-travel-time-per-km: average travel time per vehicle per kilometer (s/km) -> compare against paper's Figure 3 / Table 3.
;- actual-road-capacity: Qr/Qi, the ratio of real traffic flow rate to input flow rate -> compare against paper's Figure 4 / Table 4.
;
;## HOW TO REPRODUCE THE PAPER'S SCENES (Table 1)
;
;Set sliders to match a "scene" (y) and a flow level (z), then press setup, then run "go 1800 ticks" (the paper simulates 1800 seconds per case), then press "record scene" to log the result to the output box.
;
;Scenes (from Table 1):
;  A: mpr=0,   cav-lanes=0
;  B: mpr=25,  cav-lanes=0
;  C: mpr=25,  cav-lanes=1
;  D: mpr=50,  cav-lanes=0
;  E: mpr=50,  cav-lanes=1
;  F: mpr=50,  cav-lanes=2
;  G: mpr=75,  cav-lanes=0
;  H: mpr=75,  cav-lanes=1
;  I: mpr=75,  cav-lanes=2
;  J: mpr=100, cav-lanes=0
;
;Flow rates (input-flow-pct): 80, 100, 120, 140, 160 (% of saturation flow Qs)
;
;Running all 10 scenes x 5 flow rates (50 runs total) and recording each with "record scene" reproduces the full matrix used to build the paper's Figures 3/4 and Tables 3/4.
;
;## EXPECTED QUALITATIVE PATTERNS (from the paper, section 3.2)
;
;- Increasing MPR (0% -> 100%) generally REDUCES average travel time per km and INCREASES actual road capacity, because CAVs' shorter headway lets more vehicles flow through per unit time.
;- At UNSATURATED flow (80% Qs), adding dedicated CAV lanes (scene C, F) can HURT both travel time and capacity at low MPR, because the dedicated lane is under-utilized while it removes capacity from the general-purpose lanes (matches the paper's "negative benefits" finding).
;- At SATURATED/OVERSATURATED flow (>=100% Qs), dedicated CAV lanes at moderate-to-high MPR (E, H, I) amplify the benefits beyond what MPR alone would achieve (matches the paper's amplification finding).
;- The reduction in travel time and the gain in capacity both grow, then plateau, as MPR rises, consistent with the paper's Figures 3 and 4.
;
;## NOTES / SIMPLIFICATIONS
;
;This is a simplified illustrative model, not a VISSIM replica: it uses a lightweight gap-acceptance car-following rule (time-headway based) instead of the paper's full MIXIC and Wiedemann-99 models, and a fixed 2200 veh/h/lane saturation assumption instead of a calibrated Chinese-standard expressway capacity. The qualitative trends (travel time, capacity, and dedicated-lane effects vs. MPR and flow saturation) match the paper; exact percentages will differ from Tables 3/4 since those come from calibrated VISSIM microsimulation.

## HOW IT WORKS

Each tick (1 tick = 1 second) the model does the following, in this order:

1. **Weather.** Each weather zone may get one level worse or better (0 = clear, 3 = severe), with probability `weather-change-prob`.
2. **Arrivals.** In each of the 3 lanes, a vehicle arrives with probability `input-flow-pct` × `saturation-flow`. Each new vehicle becomes a CAV with probability `cav-fraction`, and gets its own desired speed around `base-desired-speed`. CAVs vary less in speed than HVs.
3. **Entry.** Arrivals wait at the lane entrance until there is a safe gap of speed × headway + 1 patches. CAVs use `cav-headway` and HVs use `hv-headway`. Time spent waiting counts toward travel time.
4. **Ramp.** Ramp vehicles arrive with probability `ramp-arrival-rate` and wait in a queue. The meter alternates green and red, and red lasts longer when the mainline near the ramp is denser. On green, one vehicle merges if a lane has `merge-gap-needed` patches free. If the queue grows past `queue-threshold`, the meter is forced to green.
5. **Sensing weather.** HVs see `hv-perception-patches` ahead, and CAVs see `cav-perception-patches` ahead. With RWIS on, CAVs instead see the worst weather within the next `comm-range-zones` zones.
6. **Target speed.** Each vehicle's target is its own desired speed × (1 − weather severity × `weather-speed-penalty`). HVs switch to the new target immediately. CAVs move toward it gradually, at `cav-adjustment-rate`.
7. **Moving.** Vehicles move front to back. Each one speeds up by at most `max-accel`, slows down by `max-decel`, and never goes faster than gap ÷ (1 + headway) behind the car ahead, braking harder if it has to. HVs also brake at random with probability `hv-slowdown-prob` (the Nagel–Schreckenberg rule). CAVs never brake at random.
8. **Exit.** Vehicles that reach the end of the road are removed, and their travel time is recorded.

Two patterns come out of these rules. Travel time stays flat until demand gets close to the road's capacity, then rises sharply. And because CAVs follow more closely and don't brake at random, more CAVs means higher capacity, so the sharp rise comes at a higher flow.

**Outputs:**
- **ATT** is the mean time from arrival to exit.
- **Actual road capacity** is Qr/Qi: mainline vehicles that exited divided by mainline vehicles that arrived, counted after a 300-tick warm-up.



## HOW TO USE IT



**Basic use:** set the sliders, press **setup**, then **GO** (or **go-num-ticks**). For all 125 experiments, press **run batch**.

**Buttons and inputs**

| Item | What it does |
|---|---|
| setup | Builds the road, weather zones, and ramp, and applies the seed. Always press it before running. |
| GO / step | Runs continuously (GO) or one tick at a time (step). |
| go-num-ticks / num-ticks | Runs the number of ticks in `num-ticks`. This value is also the run length for GO and the batch. |
| stop | Stops a run. |
| reset | Same as setup. |
| run batch | Runs every combination of seeds 45–49, MPR 0–100, and flow 80–160%, and writes batch_raw.csv and batch_summary.csv. |
| record / clear | Records the current results to the Output area, or clears it. |
| seed | The random seed. The same seed gives the same run; 0 picks a random seed. |
| Close Output File | Does nothing; it isn't linked to a command. |

**Traffic and road**

| Item | What it does |
|---|---|
| road-length | Road length in patches (250 used in testing). Keep it the same across experiments. |
| input-flow-pct | Demand as a percentage of all-HV lane capacity. 100% means saturated. |
| cav-fraction | Market penetration rate (MPR): the share of vehicles that are CAVs. |
| base-desired-speed | Free-flow speed in patches per tick. |
| max-accel / max-decel | The most speed can change per tick under normal driving. |
| cav-headway / hv-headway | Desired time gap to the car ahead, in ticks. |
| hv-slowdown-prob | Chance per tick that an HV brakes at random. |
| num-vehicles, cav-lanes | Not used by the current code. |

**Weather and RWIS**

| Item | What it does |
|---|---|
| num-zones | Number of weather zones along the road. |
| weather-change-prob | Chance per tick that a zone's weather changes. Set it to 0 for no weather. |
| weather-speed-penalty | How much each weather level lowers speed. |
| with-rwis? | Gives CAVs advance warning of weather from roadside stations. |
| comm-range-zones | How many zones ahead CAVs can see with RWIS. |
| hv-perception-patches / cav-perception-patches | How far ahead each vehicle type sees weather without RWIS. |
| cav-adjustment-rate | How quickly CAVs adjust their speed to the weather. |

**Ramp meter**

| Item | What it does |
|---|---|
| ramp-arrival-rate | Ramp arrivals per tick. Set it to 0 for no ramp. |
| ramp-position | Where the ramp joins the road. |
| detection-range | How far around the ramp mainline density is measured. |
| queue-threshold | Queue length that forces the meter to green. |
| green-duration-ticks, min-red-ticks, max-red-ticks | Meter timing. Red lasts longer when density is higher. |
| merge-gap-needed | Free space a ramp vehicle needs to merge. |
| merge-speed-limit | Speed of a ramp vehicle as it merges. |

**Monitors and plots**

| Item | What it shows |
|---|---|
| Average travel time | ATT in ticks. The label says s/km, but it's ticks per trip. |
| Actual road capacity | Qr/Qi. |
| Vehicles on road | Includes vehicles waiting on the ramp. |
| Plots | Average speed by vehicle type, average travel time, ramp queue length, and ramp metering rate. |

**Running the batch:**
- For the Song comparison, set `weather-change-prob` and `ramp-arrival-rate` to 0 first. The batch uses all other settings as they are on the Interface.
- Untick "view updates" to make runs much faster.
- If you change the headways, slowdown probability, or speed settings, re-measure `saturation-flow` (Case A at 150%) and update it in `setup`.

## THINGS TO NOTICE

(suggested things for the user to notice while running the model)

## THINGS TO TRY

(suggested things for the user to try to do (move sliders, switches, etc.) with the model)

## EXTENDING THE MODEL

(suggested things to add or change in the Code tab to make the model more complicated, detailed, accurate, etc.)

## NETLOGO FEATURES

(interesting or unusual features of NetLogo that the model uses, particularly in the Code tab; or where workarounds were needed for missing features)

## RELATED MODELS

(models in the NetLogo Models Library and elsewhere which are of related interest)

## CREDITS AND REFERENCES

(a reference to the model's URL on the web if it has one, as well as any other necessary credits, citations, and links)
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
