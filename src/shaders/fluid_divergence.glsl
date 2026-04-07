#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 2, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 3, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

layout(set = 0, binding = 4, std430) restrict buffer DivergenceBuffer {
    float data[];
} divergence;

const int CELL_FLUID = 1;

int u_idx(int x, int y, int w) {
    return y * (w + 1) + x;
}

int v_idx(int x, int y, int w) {
    return y * w + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) {
        divergence.data[idx] = 0.0;
        return;
    }

    // Divergence = net outflow. Positive = more flowing out than in.
    float u_left   = u_vel.data[u_idx(x, y, w)];
    float u_right  = u_vel.data[u_idx(x + 1, y, w)];
    float v_top    = v_vel.data[v_idx(x, y, w)];
    float v_bottom = v_vel.data[v_idx(x, y + 1, w)];

    // Divergence scaled by 1/dt so pressure solve produces results in correct units.
    float div = (u_right - u_left) + (v_bottom - v_top);
    divergence.data[idx] = div / params.delta_time;
}
