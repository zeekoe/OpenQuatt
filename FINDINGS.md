# Findings: run extension from a fresh start

Status: research only. No firmware code has been changed.

## 1. Requested behaviour

After a fresh start, when the room is inside the run-extension band:

```text
setpoint <= room < setpoint + stop margin
```

the heat pump should start heating at the lowest physical level (F1) instead of waiting until the room has cooled below the setpoint / normal cold edge.

The change should be limited to the fresh-start path. It must not turn run extension into a mechanism that restarts a stopped heat pump in the middle of the extension band after every stop.

## 2. Short summary of the current behaviour

Run extension (`#608`) is a state machine that only *supports an existing heating run*. It deliberately does not start an idle heat pump.

- Arming requires a real run:
  ```cpp
  if (phase_can_arm && in.cycle_active && in.actual_heating_active && in.inputs_valid &&
      in.heating_allowed) {
    next.cycle_armed = true;
  }
  ```
  (`openquatt/includes/control/oq_power_house_run_extension_logic.h:132-138`)
- A fresh boot / strategy reset creates `State{}` with `cycle_armed == false`, so there is no armed cycle.
- The `INACTIVE` branch additionally requires `in.cycle_active`; at standstill `cycle_active` is false, so even an armed state is immediately disarmed:
  ```cpp
  if (!next.cycle_armed || !in.cycle_active) {
    next.phase = Phase::INACTIVE;
    if (!in.cycle_active) next.cycle_armed = false;
    break;
  }
  ```
  (`oq_power_house_run_extension_logic.h:179-183`)
- A warm restart requires a previous `WAIT_WARM_RESTART` state, a room at/below `warm_restart_c`, and `base_requested_w > 0` (`:268-317`). A reboot has no such state.
- Normal room demand is confirmed only at the cold edge: `room_c <= setpoint - comfort_below` (`oq_heat_intent_logic.h:117-136`).
- Therefore, in the low-demand case the heat pump waits until the room reaches the cold edge. The extension floor cannot help, because extension is not armed and cannot start the unit.

Important nuance: normal Power House heating is not *strictly* gated by the room-intent cold edge. The continuous request is:

```text
requested_w = modelled house power + room feedback
```

(`oq_power_house_demand_logic.h:126-196`). Above the cold edge the room feedback is zero, but the modelled house power can still be positive. If it is high enough, normal dispatch can start the heat pump above the setpoint through the regular path. The "wait until below setpoint" behaviour is therefore strongest when the modelled house demand is low/near zero, which is exactly the low-load scenario run extension is meant to cover.

## 3. Definitions

| Term | Meaning in this codebase |
|---|---|
| F1 | Lowest physical compressor level. For V2 this is 20 Hz; for V1/V1.5 it is 30 Hz. |
| `minimum_viable_level` | The lowest level that is both frequency-policy allowed and thermal-model valid. 1-based. |
| `minimum_viable_w` | Thermal output of that lowest usable level. |
| Fresh start | Ambiguous; see section 4. |
| Run-extension band | `room >= setpoint` and `room < comfort_stop_c`, where `comfort_stop_c` is normally `setpoint + stop_margin`. |
| Warm restart | Restart after a previous stop, gated by `warm_restart_c` and `base_requested_w > 0`. |

## 4. What "fresh start" can mean

### A. Controller boot / firmware update (most likely intended)

The controller starts with empty run-extension history. The room is already above the setpoint but below the stop margin. Today the controller will not use extension until a normal run has happened.

This interpretation matches the existing documentation:

> Na reboot of firmware-update blijven de instellingen behouden, maar de historische doorverwarmen-cyclus wordt gewist. Er moet eerst weer een echte verwarmingsrun zijn voordat extension een warme herstart mag vrijgeven.

(`docs/power-house.md:361`)

The requested change would add an explicit exception: a fresh boot may *start* the first run at F1 in the band. A later warm restart still follows the normal cooldown rules.

### B. First start after activating the heating strategy / mode

Mechanically the same as A, because `reset()` is also called when Power House is not active (`oq_power_house_runtime.h:95-102`, `612-638`). A new strategy epoch would get a new fresh-start opportunity.

### C. First start after a normal stop or comfort stop

This is the existing warm-restart path. Starting immediately anywhere in the band would defeat the configured cooldown/hysteresis and cause short cycling. I recommend **not** changing this path. The fresh-start exception should be consumed once a run has actually started.

### D. First start after a long idle period without a reboot

This is not represented today. If "fresh start" is meant this way, the trigger needs a separate definition (for example, "no run for N hours" or "new heat demand after setback"). That is a larger behavioural change and is not covered by the existing state machine.

Recommendation: implement A/B as a one-shot per boot/strategy epoch, and leave C unchanged. Confirm with the user whether D is needed.

## 5. Exact current code paths

### 5.1 Run-extension state machine

File: `openquatt/includes/control/oq_power_house_run_extension_logic.h`

- Phases: `INACTIVE`, `RUNNING`, `EXTENDING`, `COMFORT_STOP`, `WAIT_WARM_RESTART`, `WARM_RESTART` (`:11-18`).
- Stop-at-setpoint / elevated-minimum rule (`:102-118`):
  ```cpp
  const bool comfort_hold = phase == COMFORT_STOP || phase == WAIT_WARM_RESTART || phase == WARM_RESTART;
  const bool elevated_minimum = in.minimum_viable_level > 1 && pmin_valid(in.minimum_viable_w) &&
                                std::isfinite(in.base_requested_w) && in.base_requested_w < in.minimum_viable_w;
  const bool stop_at_setpoint = elevated_minimum || (state.stop_at_setpoint && comfort_hold);
  const float comfort_stop_c = setpoint_c + (stop_at_setpoint ? 0.0f : stop_margin_c);
  const float warm_restart_c = std::max(comfort_stop_c - hysteresis_c, cold_edge_c);
  ```
  This is the reason F1-only is essential: at F1 the optional margin may be filled; at a higher minimum the optional margin must not be filled.
- Floor activation requires `usable`, `cycle_armed`, valid Pmin and an unconstrained water limiter (`:154-155`).
- `INACTIVE` branch (`:171-192`) only starts a normal run or an armed extension; it cannot arm itself.
- `WAIT_WARM_RESTART` branch (`:268-317`) requires `room_ready_restart` and `in.base_requested_w > 0.0f` before emitting `warm_restart_intent`.
- `WARM_RESTART` keeps intent through jitter and drops it when base demand becomes zero (`:318-371`).

### 5.2 Runtime wiring

File: `openquatt/includes/control/oq_power_house_runtime.h`

- `run_cycle_active`:
  ```cpp
  const bool run_cycle_active = applied_total > 0 || protection_hold || hp1_valve_defrost || hp2_valve_defrost ||
                                hp1_oil_return || hp2_oil_return;
  ```
  (`:446-447`). At a true standstill this is false.
- Extension input is populated at `:448-467`.
- Before a run, `minimum_viable_w` / `minimum_viable_level` come from the start-candidate scan (`:341-361`):
  - only servable HP candidates (`may_serve_candidate`, which includes availability and minimum-off readiness),
  - first allowed + thermal-valid level per HP,
  - lowest thermal output wins.
- During a run they are replaced by `minimum_active_candidate()` (`:458-463`, `oq_power_house_dispatch_logic.h:258-279`), which only considers units already running.
- The floor is applied after the state machine:
  ```cpp
  float effective_requested_w = base_requested_w;
  if (run_ext_decision.force_comfort_stop) {
    effective_requested_w = 0.0f;
  } else if (run_ext_decision.floor_active) {
    effective_requested_w = std::max(base_requested_w, run_ext_decision.floor_w);
  }
  ```
  (`:494-501`). The resulting positive request is what can make dispatch start a stopped heat pump.
- `reset()` clears `run_extension_state_` and all extension diagnostics (`:612-638`). `boot_demand_checked_` and `startup_phase_` are already one-shot boot state and are deliberately not re-armed by strategy resets (`:710`, `:759-760`).

### 5.3 Why F1 can be unavailable

`minimum_viable_level` rises above 1 when any of the following makes F1 unusable:

- F1/its frequency is outside the current frequency cap (`oq_day_max_frequency_hz` / silent cap);
- F1 is inside the user-configured frequency exclusion range;
- the ODU frequency table / variant is unknown;
- the water outlet is at/above the model boundary (from 49 °C the V2 heating map starts at 30 Hz);
- the thermal model has no valid cell at F1 for the current outside/supply temperature;
- during a run, only already-running units and their currently allowed levels are considered.

Relevant code:

- `openquatt/includes/control/oq_compressor_frequency_policy.h`
- `openquatt/includes/control/oq_compressor_frequency_runtime.h`
- `openquatt/includes/performance/hp_perf_frequency.h`
- `openquatt/includes/performance/hp_perf_map_v2.h`
- `openquatt/includes/diagnostics/oq_heating_capacity.h`
- `openquatt/includes/control/oq_odu_compressor_levels.h`

Docs already describe this at `docs/power-house.md:304` and `:308`.

### 5.4 Normal demand / cold edge

File: `openquatt/includes/control/oq_heat_intent_logic.h`

```cpp
out.room_condition = controlled_warmup
                         ? room_c < setpoint_c && room_c < observed_setpoint_c
                         : room_c <= room_cold_edge_c(setpoint_c, room_resume_delta_c);
```

(`:119-121`), with `room_cold_edge_c = setpoint - room_resume_delta_c` and `room_resume_delta_c = comfort_below` in the runtime (`oq_power_house_runtime.h:204`).

`room_confirmed` / `fast_start` / `room_recovery_active` are used to add the start/recovery floor (`oq_power_house_runtime.h:408-418`), not to gate the continuous watt request.

### 5.5 Dispatch can start a stopped HP

`decide_dispatch()` scores level 0 and all active levels against the requested watts (`oq_power_house_dispatch_logic.h:359-380`). A positive request at or above roughly half of F1's output can therefore start a stopped unit even without run extension.

This means the new fresh-start path can reuse the existing mechanism: make the state machine emit `floor_active = true` and `floor_w = minimum_viable_w`; the runtime already turns that into `effective_requested_w = max(base, floor)`.

## 6. Recommended implementation approach

### 6.1 Add an explicit fresh-start permission to the extension input

Do not infer "fresh start" from `cycle_armed == false`, because that is also true after a normal stop. Add an explicit permission owned by the runtime:

```cpp
struct Input {
  ...
  bool allow_fresh_start = false;  // one-shot per boot / strategy epoch
};
```

Optionally also add a consumed flag to the state machine so the pure logic cannot start twice even if the caller leaves the input high:

```cpp
struct State {
  ...
  bool fresh_start_consumed = false;
};
```

Runtime owns a one-shot member, for example:

```cpp
bool run_ext_fresh_start_pending_{true};  // not cleared by reset()
```

Pass it only when all of the following are true:

- Power House is active and `startup_phase_ == READY`;
- `applied_total == 0`;
- no protection hold / valve defrost / oil return (`run_cycle_active == false` for a true standstill);
- the one-shot is still pending.

Clear `run_ext_fresh_start_pending_` when:

- a run is confirmed (`applied_total > 0`), or
- the setpoint changes (recommended), or
- the strategy is explicitly disabled/reset if that should consume the opportunity (open question).

Do not clear it in `reset()` unconditionally, otherwise a boot that starts inactive would lose the opportunity. If `reset()` must clear it, preserve the initial boot value separately.

### 6.2 Add the fresh-start branch to `evaluate()`

Place it in the `INACTIVE` case before the existing `!cycle_active` disarm:

```cpp
const bool room_in_extension_band =
    room_finite && std::isfinite(in.setpoint_c) &&
    in.room_c >= in.setpoint_c && in.room_c < comfort_stop_c;

const bool fresh_start_allowed =
    in.allow_fresh_start && !state.fresh_start_consumed &&
    !in.cycle_active && !in.actual_heating_active &&
    room_in_extension_band &&
    in.minimum_viable_level == 1 &&
    pmin_valid(in.minimum_viable_w) &&
    water_floor_allowed(in.water_limit_factor) &&
    std::isfinite(in.base_requested_w) &&
    in.base_requested_w < in.minimum_viable_w;
```

If true:

```cpp
next.fresh_start_consumed = true;
next.cycle_armed = true;
next.phase = Phase::EXTENDING;
out.floor_active = true;
out.floor_w = in.minimum_viable_w;
break;
```

Notes:

- `EXTENDING` is the right phase: the run is intentionally filling the optional margin at minimum power. The existing `EXTENDING` logic keeps the floor while base is below Pmin and asks for a comfort stop at `comfort_stop_c`.
- `next.cycle_armed = true` lets the normal run-confirmation path take over as soon as `actual_heating_active` becomes true. The extension state then continues normally.
- `base_requested_w < minimum_viable_w` keeps normal demand authoritative. If the house already asks for at least Pmin, normal dispatch should choose the level, not the extension floor. This matches the existing meaning of run extension.
- `minimum_viable_level == 1` implements the "F1 only" requirement. If F1 is unavailable, do nothing and let the normal cold-edge/normal-demand path handle the start. This preserves the elevated-minimum rule at `:102-110` and the docs at `docs/power-house.md:308`.
- `water_floor_allowed()` preserves the existing water-limiter guard.
- `!in.cycle_active` prevents a fresh start while the compressor is already running or while a defrost/oil-return hold is active.
- `room >= setpoint` keeps the change strictly inside the requested band. If the user wants "at or below setpoint" too, that is a wider change and overlaps normal demand.

### 6.3 Consume the opportunity on any confirmed run

Also clear the fresh-start opportunity when the ordinary arming branch fires:

```cpp
if (phase_can_arm && in.cycle_active && in.actual_heating_active && ...) {
  next.cycle_armed = true;
  next.fresh_start_consumed = true;
}
```

This ensures:

- a normal run that starts before the band is reached consumes the opportunity;
- after that run stops, the normal cooldown/warm-restart rules apply and the unit is not immediately restarted in the band.

### 6.4 What the runtime already does for us

No dispatch changes are needed:

1. The fresh-start branch emits `floor_active` / `floor_w`.
2. `effective_requested_w` becomes `max(base, minimum_viable_w)`.
3. `decide_dispatch()` sees a positive request and selects level 1 (its thermal output exactly matches the request).
4. The existing actuator / incident / minimum-off / flow / water / defrost / oil-return guards still decide whether the compressor may actually start.
5. On the next ticks, `applied_total > 0`, `cycle_active` becomes true, and the normal extension phase continues.

### 6.5 Why not the alternatives

| Alternative | Why it is less suitable |
|---|---|
| Relax `oq_heat_intent::room_condition` to the band | Changes normal comfort demand globally, not just run extension; heat intent has no knowledge of F1 / `minimum_viable_level`; could start at high demand and fill the margin at a high level. |
| Start directly from `WAIT_WARM_RESTART` in the band | Bypasses the configured restart cooldown/hysteresis and can cause short cycling after every stop. |
| Reuse `warm_restart_intent` at boot | Warm restart is explicitly tied to a previous latched stop; using it for a boot start would blur the state semantics and the diagnostics. |
| Lower the normal cold edge while idle | Changes ordinary heating everywhere and removes the intentional start hysteresis. |
| Allow the fresh start at any `minimum_viable_level` | Reintroduces the exact problem the elevated-minimum rule was added to prevent: filling optional margin at a high compressor level. |

## 7. Guards and invariants

The fresh-start path must keep all existing guards:

- valid/fresh room and setpoint inputs;
- heating enable valid and selected;
- `demand.valid` (model, water limit factor, tuning inputs);
- `water_limit_factor >= 0.999` (no active water limiting);
- F1 is the lowest viable level (`minimum_viable_level == 1`);
- `minimum_viable_w` finite and positive;
- base demand below `minimum_viable_w`;
- no current run, defrost, valve defrost or oil return hold;
- HP candidate is servable (`may_serve_candidate`), including minimum-off time and availability;
- boot resume / boot protection hold has ended (the candidate/model path already suppresses Pmin while unavailable);
- electrical soft/peak limits and power caps;
- flow, water-temperature and actuator safety gates;
- setpoint drop / heating disable cancels the pending opportunity.

Invariants to preserve:

- Never start a stopped heat pump at a level above F1 for the optional extension margin.
- Never bypass the restart cooldown after a stop.
- Never feed the extension floor into the house-demand model or boiler deficit (already separated through `base_requested_w` / `house_requested_w`).
- Never turn the fresh start into a permanent "heat whenever above setpoint" rule.
- F1 unavailable means "no fresh start", not "start at the next available level".

## 8. Behaviour examples

Assume setpoint 21.0 °C, stop margin +0.5 °C, cold edge 20.8 °C, F1 = 1,700 W, base demand 600 W.

| Situation | Today | With the change |
|---|---|---|
| Boot, room 21.2 °C, F1 available | idle until 20.8 °C (or normal demand if feedforward is high enough) | start at F1, status `extending`, stop at 21.5 °C |
| Boot, room 21.2 °C, F1 unavailable (minimum level 3) | idle until 20.8 °C / normal demand | unchanged; no fresh start |
| Boot, room 21.6 °C (above stop) | idle | no start while above stop; if the opportunity persists, start when the room enters the band |
| Run stops at 21.5 °C, room 21.4 °C | wait until `warm_restart_c` (21.3 °C), then warm restart if base > 0 | unchanged: the fresh-start opportunity was consumed by the run |
| Normal run started earlier, then stopped | normal cooldown | unchanged: no second fresh start |

## 9. Risks

1. **Short cycling / compressor starts.** The fresh start creates a run that would not have existed. Minimum runtime, minimum off-time, the compressor movement guard and the restart cooldown limit the damage, but the number of starts can still increase. This is the main behavioural trade-off.
2. **Overheating above the setpoint.** F1 output may exceed the house loss, so the room can rise to the stop margin. That is inherent to "doorverwarmen", but the fresh start makes it happen from a standing start. Residual heat can overshoot the stop margin; the docs already warn about this.
3. **F1 availability is time-varying.** F1 may be unavailable at boot and become available later (or vice versa). The one-shot should not continuously retry at a higher level; only F1 is acceptable.
4. **Interaction with the elevated-minimum latch.** If the fresh start is implemented incorrectly, it can produce `stop_at_setpoint` or a latched stop that the user did not expect. F1-only plus the existing `elevated_minimum` condition avoids this.
5. **Boot / recovery interaction.** A fresh start during boot resume, defrost or oil return must be suppressed. The candidate availability and `run_cycle_active` checks are the intended barriers, but this needs explicit tests.
6. **Setpoint changes.** A pending fresh start should not survive a setpoint change that makes the band meaningless. Otherwise a stale opportunity can start the unit much later.
7. **Control safety review.** This is a heat-pump control behaviour change. Per `AGENTS.md`, high-risk control changes need an independent cold review before publishing.

## 10. Tests to add or update

### Host logic tests

File: `tests/host/oq_power_house_run_extension_logic_test.cpp`

Existing tests that are relevant:

- `test_idle_while_no_cycle_no_start` (`:27-35`) — must stay inactive without the fresh-start permission.
- `test_idle_without_cycle_does_not_block_normal_demand` (`:37-53`) — must stay inactive because base ≥ Pmin; add a low-base variant.
- `test_no_restart_after_reboot_reset` (`:492-501`) — this currently asserts that a reset state with room 20.7 °C, base 700 W and F1 available does not restart. With an explicit `allow_fresh_start` input the test can remain as the "no permission" case; add a companion test with permission enabled that expects `EXTENDING` + floor and still no `warm_restart_intent`.
- `test_elevated_minimum_stops_optional_extension_at_setpoint` (`:631-685`) — keep; add a fresh-start case with minimum level > 1 and assert no start.
- `test_water_limit_blocks_floor` (`:470-480`) — add fresh-start variant.
- `test_missing_pmin_no_floor` (`:482-490`) — add fresh-start variant.
- `test_restart_setting_changes_and_failure_boundaries` (`:560-590`) — add invalid-input / heating-disabled / water-limited fresh-start cases.

New tests to add:

- `test_fresh_start_f1_above_setpoint`: room in band, base below Pmin, level 1, permission true → `EXTENDING`, `floor_active`, `floor_w == Pmin`, no comfort stop.
- `test_fresh_start_requires_f1`: same but level 2/3 or missing Pmin → stays `INACTIVE`, no floor.
- `test_fresh_start_requires_band`: room below setpoint, at/above stop, or no room → no start.
- `test_fresh_start_requires_low_demand`: base ≥ Pmin → no floor; normal demand remains authoritative.
- `test_fresh_start_consumed_by_run`: permission true, fresh start, then simulate a run and a stop; permission still true but state is consumed → no second start above `warm_restart_c`.
- `test_fresh_start_cleared_on_setpoint_change`: pending permission is cleared when the setpoint changes.
- `test_fresh_start_blocked_by_water_limit_and_inputs`: water limiter / invalid inputs / heating disabled / protection hold → no start.
- `test_fresh_start_does_not_create_stop_at_setpoint`: with F1 available, `comfort_stop_c == setpoint + margin`; after starting, the normal extension stop behavior still applies.

### Runtime / Python contract tests

File: `tests/python/test_power_house_demand_contract.py`

- Add assertions that the runtime passes the new fresh-start permission into `evaluate()`.
- Keep the existing checks that `run_ext_input.inputs_valid`, reset behaviour and diagnostics are present.
- Note: this file currently has an unrelated failing assertion around `id(ph_run_extension_restart_cooldown_c).state, room_resume_delta_c` (see `WIP.md`). Do not conflate that failure with this change.

### HIL

File: `tests/hil/scenarios/run-extension.mjs`

The current stage explicitly expects an idle compressor above setpoint:

```js
(s) => close(s.roomC, 19.82) && s.frequency === 0 && s.floorW === 0 && s.phase === 'inactive',
'run extension above setpoint does not start the idle compressor', 20000
```

(`:191-193`). That expectation must change for the fresh-start case. Suggested coverage:

1. Fresh boot with room 19.82 °C, setpoint 19.5 °C, F1 available → compressor starts at 20 Hz, phase `extending`, floor approximately F1.
2. Same but F1 excluded/unavailable → compressor stays off and phase remains `inactive` (or normal demand only).
3. After the run stops, room still above `warm_restart_c` → no immediate restart; the fresh-start opportunity is consumed.
4. Water-limit/high-supply or defrost/oil-return condition → no fresh start.
5. Confirm minimum-off-time and minimum-runtime are still respected.

Update `docs/development/hil-testing.md:349-350` accordingly.

### Commands

Run the smallest relevant checks:

```bash
npm run check:host
npm run check:python
npm run check:cpp-format
```

Run the HIL extension stage only after the host/Python tests pass and after arranging hardware:

```bash
node scripts/hil/run-run-extension.mjs ...
```

For a YAML-only change (if a settings toggle is added), validate a representative target:

```bash
python3 scripts/dev.py validate --config-only --config configs/heatpump_controller_q/duo_hil.yaml
```

## 11. Documentation affected

| File | Current text / section | Needed change |
|---|---|---|
| `docs/power-house.md:292-310` | "Een stilstaande warmtepomp wordt niet zelfstandig gestart." | Add the fresh-start exception: after boot / fresh cycle, an idle HP may start at F1 in the band when house demand is below Pmin. |
| `docs/power-house.md:308` | Elevated-minimum explanation | State explicitly that the fresh start is F1-only; if F1 is unavailable, there is no fresh start. |
| `docs/power-house.md:353-361` | Status and reboot semantics | Clarify that the historical *warm restart* is still cleared, but a fresh boot may start the first run at F1 in the band. |
| `docs/web-app/instellingen.md:174-198` | "Langer doorverwarmen" UI copy | Add the fresh-start caveat; keep the cooldown examples for the post-stop path unchanged. |
| `docs/dagelijks/verwarmen.md:58-66` | User-facing extension paragraphs | "Een stilstaande warmtepomp wordt hierdoor niet gestart" needs the same fresh-start exception. |
| `docs/development/verwarmingsregeling.md:116-121` | State-machine summary | Add the fresh-start branch and its F1/one-shot constraints. |
| `docs/development/hil-testing.md:349-350` | HIL stage description | Replace "stilstand start geen run" with the new expected fresh-start coverage. |

The web UI itself likely needs no new control. The existing status (`extending`) and threshold note remain valid. If the team wants to explain the new start in the UI, add localized copy rather than a new entity; follow `openquatt/web/README.md` for both Dutch and English catalogues.

## 12. Open questions for the user

1. Does "fresh start" mean **controller boot / firmware update** only, or also **first start after activating the heating strategy**?
2. Should the fresh-start opportunity persist if the room is above the band at boot and later cools into it, or should it expire at boot?
3. Should it apply only when **house demand is below Pmin** (the extension definition), or also when normal demand is higher and the user still wants F1?
4. Should a pending fresh start be cancelled by **any setpoint change**, or only by a setpoint drop?
5. Is a **feature toggle** desired, or should this always be active?
6. Should the one-shot survive a strategy reset / mode switch, or be consumed on the first activation only?
7. Should the new start be visible as a separate status/reason (for diagnostics), or is `extending` sufficient?

Recommended defaults:

- boot / strategy epoch only;
- persist until the first run or setpoint change;
- require base below Pmin;
- F1-only, no fallback to a higher level;
- cancel on any setpoint change;
- always active, no new setting;
- reuse `extending` status.

## 13. Suggested implementation checklist

1. Add `Input.allow_fresh_start` and, if desired, `State.fresh_start_consumed`.
2. Add the `INACTIVE` fresh-start branch in `oq_power_house_run_extension_logic.h`.
3. Consume the opportunity in the normal arming branch.
4. Add the one-shot runtime flag and wire it into `run_ext_input` in `oq_power_house_runtime.h`.
5. Clear the flag on the first confirmed run and on the chosen cancellation conditions.
6. Add the host tests listed above.
7. Update the Python runtime contract test.
8. Update the HIL scenario and HIL docs.
9. Update the user and developer docs.
10. Run `npm run check:host`, `npm run check:python`, and `npm run check:cpp-format`.
11. Arrange HIL coverage and an independent control-safety review before publishing.

## 14. Non-goals

- Changing the normal cold edge or `Comfort below setpoint`.
- Changing the warm-restart cooldown/hysteresis for post-stop restarts.
- Starting an idle heat pump at F2+ to fill the optional margin.
- Starting from a defrost, oil-return, boot-resume or protection hold.
- Changing boiler-assist deficit accounting.
- Changing the elevated-minimum stop-at-setpoint behavior.
