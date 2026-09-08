# runtil

Haptic run coaching for Apple Watch. Taps your wrist when it's time to change what you're
doing — so you can run without looking at anything.

## The idea

Run/walk switching, timed intervals, and distance splits are the same state machine with a
different transition trigger. So there's one engine, driven three ways:

| Drive mode | A segment ends when… |
|---|---|
| **Heart rate** | your projected HR nears the edge of your zone |
| **Time** | the clock runs out (90s run / 60s walk, or whatever you set) |
| **Distance** | you've covered the set distance |
| **Manual** | you tap |

One drive mode per plan, so a buzz is never ambiguous. Everything else — pace warnings, zone
warnings, distance splits — rides along as *advisories* that inform without changing segments.

## Heart rate lag is a setting, not a constant

Heart rate trails effort by 20–30 seconds, and how much depends on fitness, age, heat,
hydration, and medication — beta blockers blunt it dramatically. Rather than hardcode a
guess, `lagSeconds` is editable, and it drives a real prediction:

```
projectedHR = currentHR + slope × lagSeconds
switch when projectedHR reaches (zone edge − buffer)
```

Climbing hard toward your ceiling cues you earlier than drifting up gently. After each run
the summary reports the lag it actually measured from your transitions and offers to update
the setting, so the default tunes itself with your data.

Two guardrails keep HR-driven plans stable: a **minimum segment duration** (tracks your lag
automatically) that stops run/walk flapping at the boundary, and a **maximum** so a heart
rate that never reaches the target can't leave you running forever.

## Haptic vocabulary

watchOS has no custom haptic authoring — Core Haptics is iOS-only, so there are exactly nine
fixed system taps. The vocabulary is built from *rhythm* instead, which survives being felt
through a sleeve:

| Cue | Phrase |
|---|---|
| Start running | `start · up · up` |
| Start walking | `stop · down · down` |
| Easing up (near zone ceiling) | `failure ×2` |
| Push (near zone floor) | `retry ×2` |
| Too fast / too slow | `down ×3` / `up ×3` |
| Distance split | `notification` + one click per unit |
| Workout complete | `success ×2` |

Colliding cues are resolved by priority and *dropped*, never queued — two phrases a second
apart can't be told apart.

## Starting a run

Three ways in, all from the wrist:

- **The app** — open runtil, tap a plan. Works offline; the watch keeps its own copy of the
  library, so the phone can stay home.
- **A watch face complication** — one tap from the face. Available in the circular, corner,
  inline and rectangular accessory slots.
- **Siri** — *"Start a run with runtil"*, or name one: *"Start a Zone 2 run with runtil."*
  Plan names are matched loosely, so "zone two" finds "Zone 2 run/walk".

The complication is a launcher rather than a live readout. Showing the current segment on the
face would need a shared container between the app and the widget extension, and App Groups
aren't available under free provisioning — but it would also be redundant, since watchOS
returns you to the running workout app when you raise your wrist.

## Layout

```
RuntilCore/     Pure Swift: model + cue engine + tests. Imports only Foundation,
                so the whole engine tests on a Mac in ~0.1s.
RuntilWatch/    The brain. HKWorkoutSession, CoreLocation, haptics, live UI.
Runtil/         Plan editor, zone editor, response tuning, history. Syncs over
                WatchConnectivity.
```

The workout session isn't incidental — it's what earns background runtime, and the reason
haptics reach your wrist with the screen off. It also puts the run in Fitness for free.

## Working on it

```bash
make test        # engine tests, no device needed
make run-watch   # simulated run on the watch simulator
make run-phone   # plan editor on the phone simulator
```

The simulator has no heart rate sensor and silent haptics, so `SimulatedMetricSource`
scripts a runner whose heart rate *responds* to what the plan is asking for — after a
configurable delay, reproducing the lag the engine compensates for. Every cue is written to
an on-screen log (swipe down during a run), which is how the state machine gets verified at
a desk.

```bash
PLAN="1:30" PAGE=log make run-watch   # jump straight into a plan and watch the cues
```

## Installing on your watch

Open `Runtil.xcodeproj`, set your development team on all three targets (`Runtil`,
`RuntilWatch`, `RuntilWatchWidgets`), and run to your watch. On a free personal team the app
expires after 7 days and needs reinstalling; HealthKit and background workouts work fine
either way.

The project file is committed, so it opens directly. It's still generated from `project.yml`
by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `make project` regenerates it after
changing targets or build settings, which also overwrites anything set through Xcode's UI.

Grant Health and Location permissions on first launch. Start with a timed plan — you know
exactly when each buzz should land, which makes it easy to tell whether things are working
before trusting the heart-rate logic.

## License

© 2026 Eliza Gilpin. All rights reserved.

The source is public to read, but no open-source license is granted yet — that decision is
still open. If you'd like to use or build on any of this, ask.

