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

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

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

    int this_ct = cell_type.data[y * w + x];

    // Each cell zeros its LEFT u-face (between (x-1, y) and (x, y)) and
    // its TOP v-face (between (x, y-1) and (x, y)). Combined with the
    // right-most column and bottom-most row being wall cells in the default
    // boundary, every internal face gets covered.
    //
    // A face is "active" only if at least one adjacent cell is FLUID.
    // Inactive faces are set to 0 to clear stale velocities from cells that
    // transitioned from fluid to air.
    //
    // This replaces the older "zero wall cells' faces" approach with a
    // stricter rule that also handles air-air and air-wall faces.

    // Left u-face
    int left_ct = (x > 0) ? cell_type.data[y * w + x - 1] : CELL_WALL;
    if (this_ct != CELL_FLUID && left_ct != CELL_FLUID) {
        u_vel.data[u_idx(x, y, w)] = 0.0;
    }

    // Top v-face
    int top_ct = (y > 0) ? cell_type.data[(y - 1) * w + x] : CELL_WALL;
    if (this_ct != CELL_FLUID && top_ct != CELL_FLUID) {
        v_vel.data[v_idx(x, y, w)] = 0.0;
    }

    // Right u-face (only last column handles this, to cover the final column)
    if (x == w - 1) {
        // Face at u_idx(w, y, w). Right neighbor is out-of-grid (treat as WALL).
        if (this_ct != CELL_FLUID) {
            u_vel.data[u_idx(x + 1, y, w)] = 0.0;
        }
    }

    // Bottom v-face (only last row handles this)
    if (y == h - 1) {
        // Face at v_idx(x, h, w). Bottom neighbor is out-of-grid (treat as WALL).
        if (this_ct != CELL_FLUID) {
            v_vel.data[v_idx(x, y + 1, w)] = 0.0;
        }
    }
}
