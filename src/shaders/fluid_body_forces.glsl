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

layout(set = 0, binding = 2, std430) restrict buffer VVelocity {
    float data[];
} v_vel;

const int CELL_FLUID = 1;
const float GRAVITY = 20.0;  // cells per second squared


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

    // Apply gravity to the v-velocity at the bottom face of this fluid cell.
    if (y + 1 <= h) {
        int vi = v_idx(x, y + 1, w);
        v_vel.data[vi] += GRAVITY * params.delta_time;
    }
}
