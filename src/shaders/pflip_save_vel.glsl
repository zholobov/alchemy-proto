#[compute]
#version 450

// Save current u and v velocity buffers into u_old and v_old. This snapshot
// is taken AFTER p2g+normalize but BEFORE pressure projection. The FLIP
// gather pass uses (current - old) as the velocity correction to add to
// each particle's velocity (instead of replacing it, which would be PIC).

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

layout(set = 0, binding = 3, std430) restrict buffer UOld {
    float data[];
} u_old;

layout(set = 0, binding = 4, std430) restrict buffer VOld {
    float data[];
} v_old;

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x <= w && y < h) {
        int idx = y * (w + 1) + x;
        u_old.data[idx] = u_vel.data[idx];
    }
    if (x < w && y <= h) {
        int idx = y * w + x;
        v_old.data[idx] = v_vel.data[idx];
    }
}
