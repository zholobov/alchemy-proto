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

layout(set = 0, binding = 2, std430) restrict buffer PressureBuffer {
    float data[];
} pressure;

layout(set = 0, binding = 3, std430) restrict buffer UVelocity {
    float data[];
} u_vel;

layout(set = 0, binding = 4, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const int CELL_FLUID = 1;
const int CELL_WALL = 2;

float pressure_at(int x, int y, int w, int h) {
    if (x < 0 || x >= w || y < 0 || y >= h) return 0.0;
    int idx = y * w + x;
    int ct = cell_type.data[idx];
    if (ct == CELL_WALL) return 0.0;
    return pressure.data[idx];
}

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
    if (cell_type.data[idx] != CELL_FLUID) return;

    float p_here = pressure.data[idx];

    // Subtract pressure gradient from velocities at this cell's faces.
    // Only update velocities where both sides are fluid (avoid touching walls/air edges).
    if (x > 0 && cell_type.data[idx - 1] == CELL_FLUID) {
        float p_left = pressure_at(x - 1, y, w, h);
        u_vel.data[u_idx(x, y, w)] -= (p_here - p_left);
    }
    if (x < w - 1 && cell_type.data[idx + 1] == CELL_FLUID) {
        float p_right = pressure_at(x + 1, y, w, h);
        u_vel.data[u_idx(x + 1, y, w)] -= (p_right - p_here);
    }
    if (y > 0 && cell_type.data[idx - w] == CELL_FLUID) {
        float p_top = pressure_at(x, y - 1, w, h);
        v_vel.data[v_idx(x, y, w)] -= (p_here - p_top);
    }
    if (y < h - 1 && cell_type.data[idx + w] == CELL_FLUID) {
        float p_bottom = pressure_at(x, y + 1, w, h);
        v_vel.data[v_idx(x, y + 1, w)] -= (p_bottom - p_here);
    }
}
