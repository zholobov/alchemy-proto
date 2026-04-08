#[compute]
#version 450

// Native float atomics. Requires the VK_EXT_shader_atomic_float device
// extension which Godot 4.6 enables by default on every desktop platform we
// target (NVIDIA Maxwell+, AMD GCN3+, Intel Tiger Lake+, Apple Silicon via
// MoltenVK). Replaces the pre-C4 implementation which used atomicCompSwap
// loops on uint-reinterpreted float bits; the loop was correct but hot-path
// contention in dense cells (8 particles writing to the same face every
// step) was making p2g the single most expensive pass in the pipeline.
#extension GL_EXT_shader_atomic_float : require

// Particle-to-Grid scatter. Each particle deposits its velocity onto the
// surrounding 4 MAC-grid u-faces and 4 v-faces using bilinear weights.
// Also accumulates a particle count per cell ("density") and writes the
// substance id (last writer wins, visual only).

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

layout(set = 0, binding = 2, std430) restrict buffer UVel {
    float data[];
} u_vel;

layout(set = 0, binding = 3, std430) restrict buffer VVel {
    float data[];
} v_vel;

layout(set = 0, binding = 4, std430) restrict buffer UWeights {
    float data[];
} u_weights;

layout(set = 0, binding = 5, std430) restrict buffer VWeights {
    float data[];
} v_weights;

layout(set = 0, binding = 6, std430) restrict buffer Density {
    uint data[];
} density;

layout(set = 0, binding = 7, std430) restrict buffer Substance {
    int data[];
} substance;

layout(set = 0, binding = 8, std430) restrict buffer Substance2 {
    int data[];
} substance2;

void main() {
    uint pi = gl_GlobalInvocationID.x;
    if (pi >= uint(params.particle_count)) return;

    Particle p = particles.data[pi];
    if (p.alive == 0) return;

    int w = params.grid_width;
    int h = params.grid_height;

    // Clamp particle position to interior (defensive, advect should also clamp).
    vec2 pos = clamp(p.pos, vec2(0.5), vec2(float(w) - 0.5, float(h) - 0.5));

    // ---------------- u-face scatter (vertical faces, at integer x) ----------------
    // u-face (i, j) is at world position (i, j+0.5). For a particle at (px, py),
    // the 4 surrounding u-faces have indices (i0..i0+1, j0..j0+1) where:
    //   i0 = floor(px), i.e., the integer x to the left of the particle
    //   j0 = floor(py - 0.5), i.e., the j whose face center y is just below py
    {
        float fx = pos.x;            // u-grid x is just particle x
        float fy = pos.y - 0.5;      // u-grid y offset by 0.5 (face centered between cells)
        int x0 = int(floor(fx));
        int y0 = int(floor(fy));
        int x1 = x0 + 1;
        int y1 = y0 + 1;
        float wx = fx - float(x0);
        float wy = fy - float(y0);

        float wt00 = (1.0 - wx) * (1.0 - wy);
        float wt10 = wx * (1.0 - wy);
        float wt01 = (1.0 - wx) * wy;
        float wt11 = wx * wy;

        if (x0 >= 0 && x0 <= w && y0 >= 0 && y0 < h) {
            uint si = uint(y0 * (w + 1) + x0);
            atomicAdd(u_vel.data[si], p.vel.x * wt00);
            atomicAdd(u_weights.data[si], wt00);
        }
        if (x1 >= 0 && x1 <= w && y0 >= 0 && y0 < h) {
            uint si = uint(y0 * (w + 1) + x1);
            atomicAdd(u_vel.data[si], p.vel.x * wt10);
            atomicAdd(u_weights.data[si], wt10);
        }
        if (x0 >= 0 && x0 <= w && y1 >= 0 && y1 < h) {
            uint si = uint(y1 * (w + 1) + x0);
            atomicAdd(u_vel.data[si], p.vel.x * wt01);
            atomicAdd(u_weights.data[si], wt01);
        }
        if (x1 >= 0 && x1 <= w && y1 >= 0 && y1 < h) {
            uint si = uint(y1 * (w + 1) + x1);
            atomicAdd(u_vel.data[si], p.vel.x * wt11);
            atomicAdd(u_weights.data[si], wt11);
        }
    }

    // ---------------- v-face scatter (horizontal faces, at integer y) ----------------
    // v-face (i, j) is at world position (i+0.5, j). For particle (px, py):
    //   i0 = floor(px - 0.5)
    //   j0 = floor(py)
    {
        float fx = pos.x - 0.5;
        float fy = pos.y;
        int x0 = int(floor(fx));
        int y0 = int(floor(fy));
        int x1 = x0 + 1;
        int y1 = y0 + 1;
        float wx = fx - float(x0);
        float wy = fy - float(y0);

        float wt00 = (1.0 - wx) * (1.0 - wy);
        float wt10 = wx * (1.0 - wy);
        float wt01 = (1.0 - wx) * wy;
        float wt11 = wx * wy;

        if (x0 >= 0 && x0 < w && y0 >= 0 && y0 <= h) {
            uint si = uint(y0 * w + x0);
            atomicAdd(v_vel.data[si], p.vel.y * wt00);
            atomicAdd(v_weights.data[si], wt00);
        }
        if (x1 >= 0 && x1 < w && y0 >= 0 && y0 <= h) {
            uint si = uint(y0 * w + x1);
            atomicAdd(v_vel.data[si], p.vel.y * wt10);
            atomicAdd(v_weights.data[si], wt10);
        }
        if (x0 >= 0 && x0 < w && y1 >= 0 && y1 <= h) {
            uint si = uint(y1 * w + x0);
            atomicAdd(v_vel.data[si], p.vel.y * wt01);
            atomicAdd(v_weights.data[si], wt01);
        }
        if (x1 >= 0 && x1 < w && y1 >= 0 && y1 <= h) {
            uint si = uint(y1 * w + x1);
            atomicAdd(v_vel.data[si], p.vel.y * wt11);
            atomicAdd(v_weights.data[si], wt11);
        }
    }

    // ---------------- density (particle count) and substance scatter ----------------
    // Both substance writes are racy (non-atomic). That's fine for a purely
    // visual mixing hint: substance gets whichever particle wrote last, and
    // substance2 gets one of the OTHER substance ids that collided with it.
    // If all particles in the cell share the same id, substance2 stays 0
    // and the cell renders as a single substance. If two+ different ids
    // land in the cell, substance2 becomes non-zero and the renderer
    // blends the two colors — visible mixing at the boundary.
    {
        int cx = int(floor(pos.x));
        int cy = int(floor(pos.y));
        cx = clamp(cx, 0, w - 1);
        cy = clamp(cy, 0, h - 1);
        uint cell_idx = uint(cy * w + cx);
        atomicAdd(density.data[cell_idx], 1u);

        int my_id = p.substance_id;
        int existing = substance.data[cell_idx];
        if (existing > 0 && existing != my_id) {
            // The cell already has a different substance — record it as
            // the secondary so the renderer can blend. Racy write but
            // cosmetic; if it loses to another thread, that thread will
            // have recorded a (possibly different) non-zero secondary.
            substance2.data[cell_idx] = existing;
        }
        substance.data[cell_idx] = my_id;
    }
}
