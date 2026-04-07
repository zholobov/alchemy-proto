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
    float dt = params.delta_time;

    // Subtract pressure gradient (scaled by dt) from velocities at this cell's faces.
    // Update velocities at fluid-fluid AND fluid-air boundaries (air = atmospheric = 0).
    // Skip walls (velocity is zeroed separately).

    // Left face: between (x-1, y) and (x, y)
    if (x > 0) {
        int left_idx = idx - 1;
        if (cell_type.data[left_idx] != CELL_WALL) {
            float p_left = (cell_type.data[left_idx] == CELL_FLUID) ? pressure.data[left_idx] : 0.0;
            u_vel.data[u_idx(x, y, w)] -= (p_here - p_left) * dt;
        }
    }
    // Right face: between (x, y) and (x+1, y)
    if (x < w - 1) {
        int right_idx = idx + 1;
        if (cell_type.data[right_idx] != CELL_WALL) {
            float p_right = (cell_type.data[right_idx] == CELL_FLUID) ? pressure.data[right_idx] : 0.0;
            u_vel.data[u_idx(x + 1, y, w)] -= (p_right - p_here) * dt;
        }
    }
    // Top face: between (x, y-1) and (x, y)
    if (y > 0) {
        int top_idx = idx - w;
        if (cell_type.data[top_idx] != CELL_WALL) {
            float p_top = (cell_type.data[top_idx] == CELL_FLUID) ? pressure.data[top_idx] : 0.0;
            v_vel.data[v_idx(x, y, w)] -= (p_here - p_top) * dt;
        }
    }
    // Bottom face: between (x, y) and (x, y+1)
    if (y < h - 1) {
        int bottom_idx = idx + w;
        if (cell_type.data[bottom_idx] != CELL_WALL) {
            float p_bottom = (cell_type.data[bottom_idx] == CELL_FLUID) ? pressure.data[bottom_idx] : 0.0;
            v_vel.data[v_idx(x, y + 1, w)] -= (p_bottom - p_here) * dt;
        }
    }
}
