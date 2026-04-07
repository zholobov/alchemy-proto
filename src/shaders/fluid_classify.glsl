#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer DensityBuffer {
    float data[];
} density;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;
const float FLUID_THRESHOLD = 0.05;

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;

    if (boundary.data[idx] == 0) {
        cell_type.data[idx] = CELL_WALL;
    } else if (density.data[idx] > FLUID_THRESHOLD) {
        cell_type.data[idx] = CELL_FLUID;
    } else {
        cell_type.data[idx] = CELL_AIR;
    }
}
