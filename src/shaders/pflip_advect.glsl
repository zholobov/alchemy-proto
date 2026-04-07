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
    float viscosity[];  // indexed by substance id
} substance_props;

layout(set = 0, binding = 4, std430) restrict buffer DensityField {
    float data[];  // normalized: 1.0 = PARTICLES_PER_CELL particles in this cell
} density_field;

const float GRAVITY = 60.0;        // cells per second^2 (Tier 1 tuning)
const float MAX_VELOCITY = 100.0;  // CFL: at 120 FPS, max move = 100/120 = 0.83 cells

// Per-substance drag (linear velocity damping). drag = visc * DRAG_SCALE.
// Only applied when the particle is surrounded by other particles (in a pool),
// so falling drops in air still free-fall under gravity. The density threshold
// distinguishes "lone drop" (low density) from "pool member" (high density).
const float DRAG_SCALE = 4.0;
const float POOL_DENSITY_THRESHOLD = 0.5;  // half of target → 4 of 8 particles per cell

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

    // Apply gravity (only y component, downward in screen coords).
    p.vel.y += GRAVITY * params.delta_time;

    // Density-conditional drag: only apply drag when the particle is in a
    // pool (high local density). Falling drops in air have only themselves
    // in their cell (low density) and free-fall under gravity unimpeded.
    int dcx = clamp(int(floor(p.pos.x)), 0, w - 1);
    int dcy = clamp(int(floor(p.pos.y)), 0, h - 1);
    float local_density = density_field.data[dcy * w + dcx];

    if (p.substance_id > 0 && local_density >= POOL_DENSITY_THRESHOLD) {
        float drag = substance_props.viscosity[p.substance_id] * DRAG_SCALE;
        p.vel *= max(0.0, 1.0 - drag * params.delta_time);
    }

    // CFL cap so a single huge velocity can't shoot a particle through a wall.
    float speed = length(p.vel);
    if (speed > MAX_VELOCITY) {
        p.vel *= MAX_VELOCITY / speed;
    }

    // Tentative new position.
    vec2 new_pos = p.pos + p.vel * params.delta_time;

    // Resolve x collision: if the new x cell is a wall, clamp x and zero vel.x.
    int new_cx = int(floor(new_pos.x));
    int old_cy = int(floor(p.pos.y));
    if (is_wall(new_cx, old_cy, w, h)) {
        new_pos.x = p.pos.x;
        p.vel.x = 0.0;
        new_cx = int(floor(new_pos.x));
    }

    // Resolve y collision similarly.
    int new_cy = int(floor(new_pos.y));
    if (is_wall(new_cx, new_cy, w, h)) {
        new_pos.y = p.pos.y;
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
