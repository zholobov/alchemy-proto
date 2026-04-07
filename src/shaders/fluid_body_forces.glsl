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

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;
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

    // Each cell is responsible for its TOP v-face at v_idx(x, y), which is the
    // face between cell (x, y-1) above and cell (x, y) below. This ensures every
    // interior v-face gets processed once, including the top face of the topmost
    // fluid layer (which the previous "bottom-face only" approach missed).
    int bot_ct = cell_type.data[y * w + x];
    int top_ct = (y > 0) ? cell_type.data[(y - 1) * w + x] : CELL_AIR;

    // Apply gravity only where at least one side is fluid AND neither is wall.
    // Faces bordering walls will be zeroed afterwards anyway, but applying gravity
    // there first would bias divergence computation.
    bool any_fluid = (bot_ct == CELL_FLUID) || (top_ct == CELL_FLUID);
    bool any_wall = (bot_ct == CELL_WALL) || (top_ct == CELL_WALL);

    if (any_fluid && !any_wall) {
        v_vel.data[v_idx(x, y, w)] += GRAVITY * params.delta_time;
    }
}
