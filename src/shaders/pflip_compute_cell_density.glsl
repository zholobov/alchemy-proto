#[compute]
#version 450

// Per-cell density computation for variable-density pressure projection.
// Reads cell_mass (sum of per-particle substance densities, accumulated in
// p2g via atomicAdd) and density_count (raw particle count per cell) and
// writes the arithmetic mean mass-weighted density to cell_density.
//
// For a cell with 8 water (ρ=1) + 1 mercury (ρ=13.5) particles:
//   cell_mass  = 8*1 + 1*13.5 = 21.5
//   count      = 9
//   cell_dens  = 21.5 / 9 = 2.39
//
// This replaces the earlier "read substance[idx], look up density" scheme.
// That one was racy because substance[idx] was a last-writer-wins scatter,
// so isolated mercury particles in a water cell would flicker the cell's
// density between 13.5 and 1.0 between frames, producing pressure jitter
// and shimmering particles.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellMass {
    float data[];
} cell_mass;

layout(set = 0, binding = 2, std430) restrict buffer DensityCount {
    uint data[];
} density_count;

layout(set = 0, binding = 3, std430) restrict buffer CellDensity {
    float data[];
} cell_density;

const float AIR_DENSITY = 0.0012;
const float MIN_DENSITY = 0.0012;  // floor so 1/ρ never explodes in Jacobi

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;
    if (x >= w || y >= h) return;

    int idx = y * w + x;
    uint count = density_count.data[idx];
    float rho = AIR_DENSITY;
    if (count > 0u) {
        rho = cell_mass.data[idx] / float(count);
    }
    cell_density.data[idx] = max(rho, MIN_DENSITY);
}
