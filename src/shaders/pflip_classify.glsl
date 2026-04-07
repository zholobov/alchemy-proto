#[compute]
#version 450

// PIC/FLIP cell classification with a much higher fluid threshold than the
// grid-based solver uses.
//
// Why: in PIC/FLIP, sparse cells (e.g. a 1-cell-wide falling stream with
// 1-2 particles per cell) would otherwise be classified as fluid and get
// pressure-corrected. The pressure projection sees the velocity gradient
// along the falling stream as positive divergence and tries to "fix" it
// by slowing the bottom and speeding the top, decelerating the whole stream.
//
// Solution: only treat cells with density >= 0.5 (4 of 8 target particles)
// as fluid. Sparse stream cells become AIR and are skipped by the pressure
// projection. Particles in those cells advect with their own per-particle
// velocities (free-fall under gravity).
//
// Side effect: very thin pool edges (1-3 particles per cell) are also AIR
// now, so they don't experience pressure or density correction. This is
// usually fine — pools spread to the point where the edge is dense enough
// to count as fluid, and stays there.

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

// 0.5 = at least 4 of 8 target particles per cell. Tunable.
const float FLUID_THRESHOLD = 0.5;

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
