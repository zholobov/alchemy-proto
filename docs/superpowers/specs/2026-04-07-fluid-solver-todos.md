# Fluid Solver — Future Work TODOs

## Try Volume of Fluid (VOF) / mass-conserving advection in a separate branch

**Goal:** Replace the current semi-Lagrangian density advection with a flux-based scheme that strictly conserves mass.

**Why:** The current approach uses semi-Lagrangian backward-trace advection. This creates two known issues:

1. **Mass duplication via upward bleed** — pressure-driven upward velocities at the fluid-air interface cause air cells to sample dense pool cells below, creating "haze" of false low-density fluid above pools. Currently mitigated by killing cells below 0.05 density.
2. **Mass loss at spreading edges** — when a small spawn spreads thin, edge cells eventually fall below the kill threshold and are deleted, slowly draining mass.

**Approach to try:** Flux-based advection. Each face computes a mass flux based on velocity * face_area * dt. Mass is *exchanged* between adjacent cells (subtracted from one, added to the other). This is mass-conserving by construction since all changes are balanced pairs.

**Key references:**
- Bridson, *Fluid Simulation for Computer Graphics*, ch. 5 — discusses semi-Lagrangian vs flux-based
- Foster & Fedkiw 2001 — practical mass-conservation tricks
- VOF (Volume of Fluid) methods for sharp interface tracking

**Specific changes needed:**
1. Replace `fluid_advect.glsl` with a flux-based version that:
   - For each cell, compute fluxes through all 4 faces
   - Subtract outflow, add inflow (atomic operations or two-pass)
2. Substance handling needs careful thought — substance ID can't be averaged. Options: keep nearest-source (current approach), or track substance per face instead of per cell
3. May need to handle the fluid-air interface explicitly (level set or VOF marker per cell)

**Estimated effort:** 1–3 days. Requires careful testing because flux-based schemes can have stability issues with large time steps.

**Branch suggestion:** `experiment/vof-advection`

**Decision criteria for keeping it:**
- Visible: pool edges look more natural without haze AND without sharp edges
- Mass conservation: total fluid mass stable over 1000+ frames after pour stops
- Performance: not more than 2x slower than current semi-Lagrangian
- No new artifacts (e.g., Gibbs oscillations at interfaces)

If it doesn't satisfy these, fall back to the current semi-Lagrangian + threshold-kill approach which is good enough for the prototype.
