#[compute]
#version 450

// Normalize the accumulated u/v velocities by their accumulated weights.
// After p2g, each face holds (sum of vel*weight) and (sum of weight). The
// actual face velocity is the weighted average: sum(vel*w) / sum(w).
// Also converts the integer-particle-count "density" buffer to a float
// "density_float" buffer scaled so that PARTICLES_PER_CELL maps to 1.0,
// matching the FLUID_THRESHOLD that the existing classify shader expects.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int particle_count;
} params;

layout(set = 0, binding = 1, std430) restrict buffer UVel {
    uint data[];  // packed float, becomes plain float-as-uint after this pass
} u_vel;

layout(set = 0, binding = 2, std430) restrict buffer VVel {
    uint data[];
} v_vel;

layout(set = 0, binding = 3, std430) restrict buffer UWeights {
    uint data[];
} u_weights;

layout(set = 0, binding = 4, std430) restrict buffer VWeights {
    uint data[];
} v_weights;

layout(set = 0, binding = 5, std430) restrict buffer DensityCount {
    uint data[];
} density_count;

layout(set = 0, binding = 6, std430) restrict buffer DensityFloat {
    float data[];
} density_float;

const float PARTICLES_PER_CELL = 4.0;  // 4 particles in a cell = density 1.0

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    // Normalize u faces: (w+1) x h
    if (x <= w && y < h) {
        uint u_idx = uint(y * (w + 1) + x);
        float wt = uintBitsToFloat(u_weights.data[u_idx]);
        if (wt > 1e-6) {
            float vel = uintBitsToFloat(u_vel.data[u_idx]);
            u_vel.data[u_idx] = floatBitsToUint(vel / wt);
        } else {
            u_vel.data[u_idx] = floatBitsToUint(0.0);
        }
    }

    // Normalize v faces: w x (h+1)
    if (x < w && y <= h) {
        uint v_idx = uint(y * w + x);
        float wt = uintBitsToFloat(v_weights.data[v_idx]);
        if (wt > 1e-6) {
            float vel = uintBitsToFloat(v_vel.data[v_idx]);
            v_vel.data[v_idx] = floatBitsToUint(vel / wt);
        } else {
            v_vel.data[v_idx] = floatBitsToUint(0.0);
        }
    }

    // Convert particle count to float density (normalized)
    if (x < w && y < h) {
        int cell_idx = y * w + x;
        float count = float(density_count.data[cell_idx]);
        density_float.data[cell_idx] = count / PARTICLES_PER_CELL;
    }
}
