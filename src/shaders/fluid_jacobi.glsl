#[compute]
#version 450

// Plain Jacobi pressure solver with ping-pong buffers. Converges slowly but
// is numerically well-behaved and safe against race conditions.

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

layout(set = 0, binding = 2, std430) restrict buffer DivergenceBuffer {
    float data[];
} divergence;

layout(set = 0, binding = 3, std430) restrict buffer PressureIn {
    float data[];
} pressure_in;

layout(set = 0, binding = 4, std430) restrict buffer PressureOut {
    float data[];
} pressure_out;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

float pressure_at(int x, int y, int w, int h, float current_pressure) {
    if (x < 0 || x >= w || y < 0 || y >= h) return current_pressure;
    int idx = y * w + x;
    int ct = cell_type.data[idx];
    if (ct == CELL_AIR) return 0.0;      // Free surface: atmospheric pressure.
    if (ct == CELL_WALL) return current_pressure;  // Wall: zero gradient BC.
    return pressure_in.data[idx];
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) {
        pressure_out.data[idx] = 0.0;
        return;
    }

    float current = pressure_in.data[idx];
    float p_left   = pressure_at(x - 1, y, w, h, current);
    float p_right  = pressure_at(x + 1, y, w, h, current);
    float p_top    = pressure_at(x, y - 1, w, h, current);
    float p_bottom = pressure_at(x, y + 1, w, h, current);

    float div = divergence.data[idx];
    pressure_out.data[idx] = (p_left + p_right + p_top + p_bottom - div) * 0.25;
}
