#[compute]
#version 450

// Clear all per-cell accumulator buffers at the start of each PIC step.
// Velocity buffers (u, v) and their weight accumulators must be zeroed before
// the particle-to-grid scatter pass deposits new values via atomic add.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int particle_count;
} params;

layout(set = 0, binding = 1, std430) restrict buffer UVel {
    float data[];
} u_vel;

layout(set = 0, binding = 2, std430) restrict buffer VVel {
    float data[];
} v_vel;

layout(set = 0, binding = 3, std430) restrict buffer UWeights {
    float data[];
} u_weights;

layout(set = 0, binding = 4, std430) restrict buffer VWeights {
    float data[];
} v_weights;

layout(set = 0, binding = 5, std430) restrict buffer Density {
    uint data[];
} density;  // particle count per cell, atomic add

layout(set = 0, binding = 6, std430) restrict buffer Substance {
    int data[];
} substance;  // substance id of last particle in cell (race, but visual only)

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    // u-grid is (w+1) x h, v-grid is w x (h+1).
    // For simplicity, we dispatch over max(w+1, w) x max(h, h+1) and check bounds per buffer.

    if (x <= w && y < h) {
        u_vel.data[y * (w + 1) + x] = 0.0;
        u_weights.data[y * (w + 1) + x] = 0.0;
    }
    if (x < w && y <= h) {
        v_vel.data[y * w + x] = 0.0;
        v_weights.data[y * w + x] = 0.0;
    }
    if (x < w && y < h) {
        density.data[y * w + x] = 0u;
        substance.data[y * w + x] = 0;
    }
}
