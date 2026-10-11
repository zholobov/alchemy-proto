# Blocky-grid probe — performance results

Raw measurements from the CPU-only spike probe on branch `experiment/blocky-grid`
(`spike/blocky_probe.gd`, published at https://zholobov.github.io/alchemy-proto/).
Kept here so the numbers survive the probe's deletion and can inform later
decisions about grid size, tick rate, platform floor, and whether the sim core
needs compiled code.

## What the probe measures

One pure-GDScript tick over the whole grid, no shaders, no RenderingDevice:

| Pass | Work |
|---|---|
| move | falling-sand CA: powder, liquid, gas, cohesive solids, density swaps |
| temp | pairwise heat exchange, conductivity, heat capacity, latent heat, burner + torch |
| solution | solute diffusion and purity mixing between liquid cells |
| react | data-driven pair reactions (combustion = wood + air, dissolution, condensation), phase changes |
| light | radiate from glow crystals and fires, radius 6 |
| magnet | pull ferrous powder toward a magnet, radius 12 |
| electric | breadth-first conduction from an electrode |
| scan | per-substance counts, purity, pressure (goal check + lid) |
| render | every cell composited into one nearest-filtered ImageTexture, every frame |

Scenario: layered water + oil filling ~55% of the cauldron, sand and iron piles,
salt clusters dissolving, stone blocks, floating wood lit by a torch, steam in the
air. ~42–45% of cells occupied at every size. Tick at 10 Hz; render every frame.

"CPU busy" = (tick ms × tick rate + render ms × FPS) / 10, i.e. percent of one
second spent in sim + render. On an overloaded device it is misleading because the
engine drops frames, so the render term shrinks — compare tick and render ms instead.

Caveat: tick averages cover the last 120 ticks; at large sizes the screenshots were
taken only 8–30 ticks after switching size, so those averages rest on few samples.
Per-pass numbers are averaged since the grid was (re)started.

## 1. Phone — playtester, 2026-10-11

Android 10, Chrome 154 (Chromium reduced user-agent hides the model; Android 10
suggests a 2019–2020 device). Web export, Compatibility renderer, single-threaded.
Download time was not captured.

### Burner off

| Grid | Occupied | Pairs | Tick avg | Tick max | Render | FPS | Busy |
|---|---|---|---|---|---|---|---|
| 64x48 | 1302 | 193 | 36.5 | 82.9 | 5.0 | 49 | ~61% |
| 96x72 | 2915 | 300 | 71.8 | 74.9 | 10.6 | 18 | ~90% |
| 128x96 | 5289 | 678 | 126.0 | 127.0 | 18.6 | 7 | ~139% |
| 160x120 | 8602 | 1347 | 197.7 | 199.7 | 29.1 | 4 | ~209% |
| 200x150 | 13647 | 2183 | 308.2 | 312.8 | 45.4 | 2 | ~317% |

Per pass, ms per tick:

| Grid | move | temp | solution | react | light | magnet | electric | scan |
|---|---|---|---|---|---|---|---|---|
| 64x48 | 14.6 | 12.2 | 4.4 | 4.1 | 0.0 | 0.4 | 0.0 | 1.9 |
| 96x72 | 27.2 | 22.8 | 9.0 | 8.4 | 0.2 | 0.3 | 0.0 | 3.9 |
| 128x96 | 48.7 | 38.5 | 15.8 | 15.4 | 0.2 | 0.3 | 0.1 | 7.0 |
| 160x120 | 77.3 | 59.8 | 24.6 | 24.5 | 0.0 | 0.4 | 0.1 | 10.9 |
| 200x150 | 120.2 | 93.4 | 38.5 | 38.4 | 0.1 | 0.4 | 0.1 | 17.2 |

### Burner on

| Grid | Occupied | Pairs | Tick avg | Tick max | Render | FPS | Busy |
|---|---|---|---|---|---|---|---|
| 64x48 | 1309 | 311 | 35.5 | 48.2 | 5.0 | 48 | ~59% |
| 96x72 | 2990 | 628 | 71.9 | 83.1 | 10.6 | 16 | ~88% |
| 128x96 | 5439 | 1100 | 125.8 | 127.4 | 18.7 | 7 | ~138% |
| 160x120 | 8702 | 1633 | 197.2 | 199.8 | 29.2 | 5 | ~211% |
| 200x150 | 13687 | 2270 | 306.7 | 309.7 | 45.5 | 2 | ~315% |

Per pass, ms per tick:

| Grid | move | temp | solution | react | light | magnet | electric | scan |
|---|---|---|---|---|---|---|---|---|
| 64x48 | 14.0 | 11.2 | 4.2 | 3.9 | 0.0 | 0.4 | 0.0 | 1.8 |
| 96x72 | 27.2 | 22.6 | 8.8 | 8.8 | 0.2 | 0.3 | 0.0 | 3.9 |
| 128x96 | 47.9 | 38.9 | 15.7 | 15.6 | 0.2 | 0.4 | 0.1 | 7.0 |
| 160x120 | 75.9 | 60.6 | 24.6 | 24.6 | 0.1 | 0.3 | 0.1 | 10.9 |
| 200x150 | 118.9 | 93.3 | 38.4 | 38.4 | 0.1 | 0.4 | 0.1 | 17.1 |

Observations:
- Cost is linear: ~10–12 µs per cell per tick, ~1.5 µs per cell per render.
- Burner on vs off makes no measurable difference.
- move + temp = ~73% of the tick at every size.
- Even at 64x48 the whole tick runs inside one frame, so a 36–83 ms frame lands
  every 100 ms: visible stutter on top of the ~49 FPS average.

## 2. Mac browser — owner's machine, 2026-10-11

Apple M5 Max, Microsoft Edge on Chromium 154 (same browser engine as the phone),
the published page, burner on.

| Grid | Occupied | Pairs | Tick avg | Tick max | Render | FPS | Busy | Ticks sampled |
|---|---|---|---|---|---|---|---|---|
| 64x48 | 1331 | 326 | 3.4 | 4.1 | 0.4 | 60 | ~6% | 27 |
| 96x72 | 3063 | 707 | 7.7 | 8.2 | 1.0 | 60 | ~13% | 16 |
| 128x96 | 5481 | 1066 | 9.3 | 9.5 | 1.3 | 60 | ~16% | 9 |
| 160x120 | 8650 | 1636 | 17.9 | 18.8 | 2.3 | 60 | ~31% | 18 |
| 200x150 | 13480 | 2414 | 22.5 | 24.6 | 3.0 | 60 | ~40% | 21 |

Per pass, ms per tick:

| Grid | move | temp | solution | react | light | magnet | electric | scan |
|---|---|---|---|---|---|---|---|---|
| 64x48 | 1.2 | 1.1 | 0.4 | 0.4 | 0.0 | 0.0 | 0.0 | 0.2 |
| 96x72 | 3.0 | 2.3 | 1.0 | 0.9 | 0.1 | 0.0 | 0.0 | 0.4 |
| 128x96 | 3.6 | 2.9 | 1.2 | 1.2 | 0.0 | 0.0 | 0.0 | 0.5 |
| 160x120 | 7.2 | 5.5 | 2.2 | 2.1 | 0.0 | 0.0 | 0.0 | 0.9 |
| 200x150 | 8.7 | 7.0 | 2.9 | 2.7 | 0.0 | 0.0 | 0.0 | 1.2 |

## 3. Mac native and headless browser — 2026-10-10

Same M5 Max. Native = `godot --path . spike/blocky_probe.tscn` (first probe commit,
burner on by default at the time). Headless = Microsoft Edge 155 `--headless=new`
with SwiftShader WebGL, loading the web export.

| Grid | Native tick | Native render | Headless tick | Headless render |
|---|---|---|---|---|
| 64x48 | 2.71 | 0.38 | ~2.5 | ~0.35 |
| 96x72 | 6.03 | 0.79 | — | — |
| 128x96 | 10.99 | 1.48 | — | — |
| 160x120 | 17.05 | 2.20 | — | — |
| 200x150 | 25.96 | 3.37 | — | — |

Native per pass at 200x150: move 9.4, temp 8.8, solution 3.2, react 3.2, scan 1.4.

Machine load matters: with other work running, the same native run measured
5.96 ms at 64x48 and 11.40 ms at 96x72, about 2.2x slower.

## 4. Ratios and rules of thumb

Phone vs Mac browser, same Chromium 154, burner on:

| Grid | Tick ratio | Render ratio |
|---|---|---|
| 64x48 | 10.4x | 12.5x |
| 96x72 | 9.3x | 10.6x |
| 128x96 | 13.5x | 14.4x |
| 160x120 | 11.0x | 12.7x |
| 200x150 | 13.6x | 15.2x |

- The phone is **~12x slower** than the M5 Max in the same browser engine.
- GDScript inside WASM in a Chromium browser runs at roughly **native speed** on the
  Mac, so the web export itself costs almost nothing for this workload.
- For GDScript builds, **Mac-browser tick and render ms × the target device's ratio**
  predicts that device. Re-calibrate if the sim core moves to compiled code: an
  interpreter-bound and a memory-bound workload need not scale the same way.
- Per-cell cost on the Mac: ~0.75–1.1 µs per tick, ~0.1 µs per render.

## 5. Decisions informed so far

- 2026-10-11: phones ruled out as a target for UX reasons (cell-level inspection and
  precise tool use need a pointer and screen space), not for speed alone. Desktop web
  browser becomes the floor. See section 6 for what that floor means relative to the
  M5 Max.

## 6. Desktop floor — what "bottom to mid-range PC" means relative to the M5 Max

Research done 2026-10-11. The workload is single-threaded (the web build has no
threads), branchy, interpreter-bound code, so single-core benchmarks are the proxy.

### Which benchmark predicts this workload

Two proxies against the one measured device:

| Proxy | M5 Max | 2019–2020 mid-range Android, Snapdragon 665 class | Predicted ratio |
|---|---|---|---|
| Geekbench 6 single-core | 4,268 | 334–435 | 10–13x |
| PassMark single-thread | 5,965 | 995 | 6x |
| **Measured, probe** | | | **~12x** |

Geekbench 6 single-core matched the measurement; PassMark under-predicted by 2x and
compresses the low end generally. Caveat: the phone's model is unknown — if it is
not Snapdragon 665 class this calibration shifts. Use Geekbench 6 single-core.

### Ratios for common PC CPUs, Geekbench 6 single-core vs M5 Max 4,268

| CPU | Typical machine | GB6 SC | Ratio | PassMark ST ratio |
|---|---|---|---|---|
| Celeron N4020 | Chromebooks, cheapest laptops 2020–2022 | ~400 | ~10.6x | 5.3x |
| Ryzen 5 3500U | 2019 budget/mainstream laptop | ~850 | ~5.0x | 3.1x |
| Core i5-8250U | 2017–2018 mainstream laptop | ~1,130 | ~3.8x | 3.2x |
| Core i5-10210U | 2019–2020 mainstream laptop | ~1,170–1,290 | ~3.5x | 2.9x |
| Intel N100 | 2023+ budget laptop / mini PC | ~1,220 | ~3.5x | 3.2x |
| Ryzen 5 7520U | 2022+ budget laptop | ~1,270 | ~3.4x | 2.5x |
| Ryzen 5 3600 | 2019 mid desktop | ~1,750 | ~2.4x | 2.3x |
| Core i5-1235U / i3-1215U | 2022 mainstream laptop | ~2,100–2,180 | ~2.0x | 2.0x |
| Core i5-12400 | 2022 mid desktop | ~2,180 | ~2.0x | 1.7x |

GB6 figures are third-party aggregates and single runs, not official medians —
treat each as ±15%. The Geekbench Browser itself sits behind a bot challenge and
could not be read directly.

### Reading

- **Mid-range PC today: ~2x.** New budget laptops (N100, Ryzen 5 7520U): ~3.5x.
- **5x** corresponds to a 2019 budget laptop (Ryzen 5 3500U class). It covers every
  mainstream laptop from ~2018 on and every new budget laptop with ~1.4x margin for
  battery saver, thermal throttling, background load, and browser differences.
- **Excluded by 5x:** Celeron / Pentium Silver / older Atom machines and most
  Chromebooks, at ~10x — the same class as the phone.

### What a 5x floor means for grid size (GDScript, 10 Hz, render only on tick)

Mac-browser tick and render × 5:

| Grid | Floor tick ms | Floor busy |
|---|---|---|
| 64x48 | ~17 | ~19% |
| 96x72 | ~38 | ~43% |
| 128x96 | ~47–55 | ~55–62% |
| 160x120 | ~90 | ~95% |
| 200x150 | ~112 | ~120% |

Rule of thumb: with render-on-tick, keep the Mac browser under ~10% CPU busy to stay
under ~50% on the floor machine. A 38 ms tick must be spread across several frames
or it stutters at 60 FPS.

### Sources

- M5 Max GB6 single-core 4,268: MacRumors, https://macrumors.com/2026/03/05/m5-max-geekbench-benchmarks/ ; 9to5Mac, https://9to5mac.com/2026/03/05/heres-how-the-new-m5-max-chip-did-on-early-geekbench-tests/
- PassMark single-thread chart, read 2026-10-11: https://www.cpubenchmark.net/singleThread.html
- i3-1215U 2,184 and Ryzen 5 7520U 1,270: https://nanoreview.net/en/cpu-compare/intel-core-i3-1215u-vs-amd-ryzen-5-7520u
- Celeron N4020 402: https://www.cpu-monkey.com/en/benchmark-intel_celeron_n4020-geekbench_6_single_core
- N100 1,222: https://laptopmedia.com/?p=1204194
- i5-8250U 1,127: https://www.cpu-monkey.com/en/benchmark-intel_core_i5_8250u-geekbench_6_single_core
- Snapdragon 665 334–435: https://www.cpu-monkey.com/en/benchmark-qualcomm_snapdragon_665-geekbench_6_single_core ; https://www.notebookcheck.net/SD-665-vs-Helio-G85-vs-SD-662_11487_12751_12771.247596.0.html
- i5-1235U ~2,095 median: https://www.notebookcheck.net/Intel-Core-i5-1235U-Processor-Benchmarks-and-Specs.589637.0.html
- Ryzen 5 3500U ~850: https://browser.geekbench.com/processors/2590 ; https://www.hardwaredb.net/ryzen-5-3500u-vs-core-i5-6600
- Ryzen 5 3600 ~1,750: user runs, e.g. https://browser.geekbench.com/v6/cpu/8689562
- i5-10210U 1,172–1,286: https://www.cpu-monkey.com/en/benchmark-intel_core_i5_10210u-geekbench_6_single_core ; https://nanoreview.net/en/cpu/intel-core-i5-10210u
- i5-12400 2,181: https://www.cpu-monkey.com/fr/benchmark-intel_core_i5_12400-geekbench_6_single_core
