#[compute]
#version 450

// PIC/FLIP density correction.
//
// Standard pressure projection enforces velocity ∇·u = 0 (mass-conservation
// in the velocity field), but it does NOT enforce a target density on the
// particles themselves. Without this correction, particles in low-pressure
// regions (e.g. the bottom of a curved container) cluster arbitrarily tight,
// because there's no force pushing them apart once they've stopped moving.
//
// Fix: for each cell with density > target, subtract a term from the divergence
// buffer. The Jacobi solve interprets this as "this cell is being compressed",
// generates high pressure here, and the gradient step pushes neighboring face
// velocities outward. The next g2p picks up those outward velocities and
// transfers them to the particles, which then drift apart.
//
// This must run AFTER fluid_divergence (which writes to the buffer) and BEFORE
// fluid_jacobi (which reads it).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer DensityFloat {
    float data[];
} density;

layout(set = 0, binding = 2, std430) restrict buffer CellTypeBuffer {
    int data[];
} cell_type;

layout(set = 0, binding = 3, std430) restrict buffer DivergenceBuffer {
    float data[];
} divergence;

const int CELL_FLUID = 1;
const float TARGET_DENSITY = 1.0;       // = PARTICLES_PER_CELL particles per cell
const float DENSITY_STIFFNESS = 500.0;  // tunable; higher = stronger spreading

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (cell_type.data[idx] != CELL_FLUID) return;

    float d = density.data[idx];
    float excess = max(0.0, d - TARGET_DENSITY);
    if (excess <= 0.0) return;

    // Subtract from divergence (make it more negative). In our pressure-solve
    // sign convention (Jacobi solves ∇²p = +divergence), negative divergence
    // creates high pressure at this cell, which then pushes particles outward
    // in the gradient pass.
    divergence.data[idx] -= excess * DENSITY_STIFFNESS;
}
