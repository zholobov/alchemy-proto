#[compute]
#version 450

// Particle advection. After pressure projection and g2p, each particle has
// a divergence-free velocity. This pass applies gravity and moves the
// particle by velocity*dt. Particles that try to enter a wall cell are
// pushed back to the cell boundary and have their normal velocity zeroed.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int particle_count;
} params;

struct Particle {
    vec2 pos;
    vec2 vel;
    int substance_id;
    int alive;
};

layout(set = 0, binding = 1, std430) restrict buffer ParticleBuffer {
    Particle data[];
} particles;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];  // 1 = interior, 0 = wall
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer SubstanceProperties {
    // vec4 per substance id. .x = viscosity, .y = flip_ratio (g2p),
    // .z = density, .w = reserved.
    vec4 data[];
} substance_props;

layout(set = 0, binding = 4, std430) restrict buffer DensityField {
    float data[];  // normalized: 1.0 = PARTICLES_PER_CELL particles in this cell
} density_field;

layout(set = 0, binding = 5, std430) restrict buffer AmbientDensity {
    // Per-cell ambient density in the same normalized scale as SubstanceDef
    // (water = 1.0, air = 0.0012). Receptacle computes this each frame from
    // liquid_readback and vapor_sim markers, uploads via upload_ambient_density.
    // The advect shader samples a 3x3 neighborhood to compute local ambient
    // for Archimedes buoyancy.
    float data[];
} ambient_density;

layout(set = 0, binding = 6, std430) restrict buffer Temperature {
    // Per-cell temperature in °C. Uploaded each frame from grid.temperatures.
    // Used for thermal buoyancy — hot fluid has effectively lower density.
    float data[];
} temperature;

const float GRAVITY = 60.0;        // cells per second^2 (Tier 1 tuning)
const float MAX_VELOCITY = 100.0;  // CFL: at 120 FPS, max move = 100/120 = 0.83 cells
const float AIR_DENSITY = 0.0012;  // normalized air density (water = 1.0)

// Thermal expansion coefficient. Real water is ~0.0002/°C; we use 0.005
// (25x exaggerated) so convection is visually obvious. At 80°C above
// reference the density drops by 40%, causing noticeable rising.
const float THERMAL_EXPANSION = 0.005;
const float REFERENCE_TEMP = 20.0;

// Per-substance drag (linear velocity damping). drag = visc * DRAG_SCALE.
// Two conditions must be met for drag to apply:
//   1. local density >= POOL_DENSITY_THRESHOLD (the particle is in a pool, not
//      a lone drop)
//   2. particle speed < DRAG_SPEED_FALLOFF (the particle is "settled", not
//      free-falling). Drag fades out smoothly as speed approaches the falloff.
//
// This way a falling BLOB (dense but fast-moving) doesn't get drag and falls
// at the same rate as escaped drops, while a SETTLED POOL (dense and slow)
// does get drag and feels sluggish.
const float DRAG_SCALE = 4.0;
const float POOL_DENSITY_THRESHOLD = 0.5;  // half of target → 4 of 8 particles per cell
const float DRAG_SPEED_FALLOFF = 50.0;     // drag = 0 at this speed and above

bool is_wall(int cx, int cy, int w, int h) {
    if (cx < 0 || cx >= w || cy < 0 || cy >= h) return true;
    return boundary.data[cy * w + cx] == 0;
}

void main() {
    uint pi = gl_GlobalInvocationID.x;
    if (pi >= uint(params.particle_count)) return;

    Particle p = particles.data[pi];
    if (p.alive == 0) return;

    int w = params.grid_width;
    int h = params.grid_height;

    // Cardinal-neighbor buoyancy. Apply Archimedes only when the particle
    // is mostly submerged in denser fluid — i.e. at least 2 out of 4
    // cardinal neighbors (up, down, left, right) are significantly denser
    // than self. Otherwise use plain gravity.
    //
    // This is stricter than "any denser neighbor" and fixes a class of
    // bugs where a SINGLE stray denser cell above a water particle (e.g.
    // a mercury droplet hovering above a water pool) triggered full
    // Archimedes buoyancy and shot water upward in spurious explosions.
    // A truly submerged object will have denser fluid on most sides; a
    // stray droplet hovering above only produces 1 denser neighbor, so
    // buoyancy doesn't fire and both particles just fall under gravity.
    //
    // Behavior cheatsheet:
    //  water pool interior                    → 0 denser nbrs → g
    //  falling water blob                     → 0 denser nbrs → g
    //  water with 1 stray mercury above       → 1 denser  → g ✓ no explosion
    //  water fully surrounded by mercury      → 4 denser  → rises (−3g clamp)
    //  gas bubble 1 cell in water             → 4 denser  → rises fast
    //  oil droplet 1 cell in water            → 4 denser  → rises slow
    //  mercury in water                       → 0 denser  → sinks under g
    //  hot water parcel in cold water         → 4 denser (thermal) → rises
    const float PHASE_INTERFACE_THRESHOLD = 0.05;

    int cx = clamp(int(floor(p.pos.x)), 0, w - 1);
    int cy = clamp(int(floor(p.pos.y)), 0, h - 1);

    // Base density from substance table, then modulate by cell temperature.
    float self_density = substance_props.data[p.substance_id].z;
    float cell_temp = temperature.data[cy * w + cx];
    float thermal_factor = 1.0 - THERMAL_EXPANSION * (cell_temp - REFERENCE_TEMP);
    thermal_factor = clamp(thermal_factor, 0.1, 2.0);
    self_density *= thermal_factor;

    float buoyancy_threshold = self_density * (1.0 + PHASE_INTERFACE_THRESHOLD);

    // Count cardinal neighbors whose ambient density is significantly denser
    // than our thermal-modulated self density. Accumulate their densities so
    // we can compute an average ambient for the Archimedes formula.
    int denser_count = 0;
    float denser_sum = 0.0;

    if (cx - 1 >= 0) {
        float d = ambient_density.data[cy * w + (cx - 1)];
        if (d > buoyancy_threshold) {
            denser_count++;
            denser_sum += d;
        }
    }
    if (cx + 1 < w) {
        float d = ambient_density.data[cy * w + (cx + 1)];
        if (d > buoyancy_threshold) {
            denser_count++;
            denser_sum += d;
        }
    }
    if (cy - 1 >= 0) {
        float d = ambient_density.data[(cy - 1) * w + cx];
        if (d > buoyancy_threshold) {
            denser_count++;
            denser_sum += d;
        }
    }
    if (cy + 1 < h) {
        float d = ambient_density.data[(cy + 1) * w + cx];
        if (d > buoyancy_threshold) {
            denser_count++;
            denser_sum += d;
        }
    }

    float effective_g = GRAVITY;
    if (denser_count >= 2 && self_density > 0.0001) {
        // "Mostly submerged" — apply Archimedes using the denser cells as
        // the ambient fluid we're displacing.
        float ambient = denser_sum / float(denser_count);
        effective_g = GRAVITY * (1.0 - ambient / self_density);
        // Clamp extreme rises. Gas-in-water gives -1666g; -3g still looks
        // visually dramatic without blowing the integration step.
        effective_g = max(effective_g, -3.0 * GRAVITY);
    }
    // else: not enough denser cells around us — gravity only
    p.vel.y += effective_g * params.delta_time;

    // Density-and-speed-conditional drag. Drag only applies if the particle
    // is in a dense region AND moving slowly (settled in a pool). A falling
    // blob is dense but fast → no drag, falls at same rate as lone drops.
    int dcx = clamp(int(floor(p.pos.x)), 0, w - 1);
    int dcy = clamp(int(floor(p.pos.y)), 0, h - 1);
    float local_density = density_field.data[dcy * w + dcx];

    if (p.substance_id > 0 && local_density >= POOL_DENSITY_THRESHOLD) {
        float speed = length(p.vel);
        // Linear falloff: full drag at speed=0, zero drag at speed >= falloff
        float speed_factor = clamp(1.0 - speed / DRAG_SPEED_FALLOFF, 0.0, 1.0);
        float drag = substance_props.data[p.substance_id].x * DRAG_SCALE * speed_factor;
        p.vel *= max(0.0, 1.0 - drag * params.delta_time);
    }

    // CFL cap so a single huge velocity can't shoot a particle through a wall.
    float speed = length(p.vel);
    if (speed > MAX_VELOCITY) {
        p.vel *= MAX_VELOCITY / speed;
    }

    // Tentative new position.
    vec2 new_pos = p.pos + p.vel * params.delta_time;

    // Resolve x then y independently, so particles slide along walls instead
    // of sticking at inside corners. On a wall hit we clamp the particle to
    // the edge of its CURRENT cell closest to the attempted-move direction,
    // which preserves the valid fraction of the motion. (Previously we reset
    // position to p.pos, losing any progress this sub-step.)
    //
    // SAFE_MARGIN keeps the particle unambiguously inside the current cell
    // after clamping, avoiding floating-point edge-classification issues.
    const float SAFE_MARGIN = 0.001;

    int old_cx = int(floor(p.pos.x));
    int old_cy = int(floor(p.pos.y));

    int new_cx = int(floor(new_pos.x));
    if (is_wall(new_cx, old_cy, w, h)) {
        // Would enter a wall cell — clamp to the matching edge of old_cx.
        if (new_cx > old_cx) {
            new_pos.x = float(old_cx + 1) - SAFE_MARGIN;  // moving right, cling to right edge
        } else if (new_cx < old_cx) {
            new_pos.x = float(old_cx) + SAFE_MARGIN;       // moving left, cling to left edge
        } else {
            new_pos.x = p.pos.x;  // already inside a wall somehow — don't move
        }
        p.vel.x = 0.0;
    }

    int resolved_cx = int(floor(new_pos.x));
    int new_cy = int(floor(new_pos.y));
    if (is_wall(resolved_cx, new_cy, w, h)) {
        if (new_cy > old_cy) {
            new_pos.y = float(old_cy + 1) - SAFE_MARGIN;   // moving down, cling to bottom edge
        } else if (new_cy < old_cy) {
            new_pos.y = float(old_cy) + SAFE_MARGIN;        // moving up, cling to top edge
        } else {
            new_pos.y = p.pos.y;
        }
        p.vel.y = 0.0;
    }

    // Final clamp to grid bounds (defensive).
    new_pos.x = clamp(new_pos.x, 0.5, float(w) - 0.5);
    new_pos.y = clamp(new_pos.y, 0.5, float(h) - 0.5);

    // If the final cell is somehow still a wall, the particle is in trouble.
    // Push it to the nearest interior neighbor (4-connected search).
    int fcx = int(floor(new_pos.x));
    int fcy = int(floor(new_pos.y));
    if (is_wall(fcx, fcy, w, h)) {
        if (!is_wall(fcx, fcy - 1, w, h)) { new_pos.y = float(fcy) - 0.5; }
        else if (!is_wall(fcx, fcy + 1, w, h)) { new_pos.y = float(fcy) + 1.5; }
        else if (!is_wall(fcx - 1, fcy, w, h)) { new_pos.x = float(fcx) - 0.5; }
        else if (!is_wall(fcx + 1, fcy, w, h)) { new_pos.x = float(fcx) + 1.5; }
    }

    p.pos = new_pos;
    particles.data[pi] = p;
}
