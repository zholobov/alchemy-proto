#[compute]
#version 450

// Kill pass for the mediator's "destroy liquid in this cell" API.
//
// The mediator tracks a per-cell kill mask on the CPU and uploads it to
// the GPU whenever a reaction consumes a liquid. This shader reads that
// mask: for each particle, look up its current cell and if the mask bit
// is set, mark the particle dead (alive = 0). Runs once at the top of
// ParticleFluidSolver.step(), before the substep loop, so the remaining
// substeps act on the culled particle set.
//
// Particles marked dead stay in the buffer — their slots are reused on
// the next spawn_particles_batch once the alive counter catches up. This
// matches how PIC/FLIP already handles dead slots.

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

layout(set = 0, binding = 2, std430) restrict buffer KillMask {
    int data[];  // 1 = kill particles whose current cell is this, 0 = keep
} kill_mask;

void main() {
    uint pi = gl_GlobalInvocationID.x;
    if (pi >= uint(params.particle_count)) return;

    Particle p = particles.data[pi];
    if (p.alive == 0) return;

    int w = params.grid_width;
    int h = params.grid_height;
    int cx = clamp(int(floor(p.pos.x)), 0, w - 1);
    int cy = clamp(int(floor(p.pos.y)), 0, h - 1);
    int cell_idx = cy * w + cx;

    if (kill_mask.data[cell_idx] != 0) {
        p.alive = 0;
        particles.data[pi] = p;
    }
}
