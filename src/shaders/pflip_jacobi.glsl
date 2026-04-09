#[compute]
#version 450

// Variable-density Jacobi pressure solver. Solves the weighted Poisson
// equation  ∇·((1/ρ)∇p) = ∇·u/dt , which is the correct formulation for a
// fluid whose density varies across the domain (mercury + water, oil +
// water, etc.). Without the 1/ρ weighting, the uniform-density Jacobi
// treats mercury-on-water as a stable equilibrium and mercury never sinks.
//
// Discretization: harmonic mean of cell densities at each MAC face, i.e.
//   1/ρ_face = (1/ρ_left + 1/ρ_right) / 2
// which is the natural finite-volume form for a weighted Laplacian.
//
// Boundary conditions:
//  - Fluid-fluid face: harmonic mean as above.
//  - Fluid-air face:  free surface, p_air = 0. Uses the fluid cell's own
//    1/ρ as the face weight. Pressure contribution from the air side is 0.
//  - Fluid-wall face: zero-gradient. The face contributes 0 to both
//    numerator and denominator of the Jacobi update — the wall "mirrors"
//    the center pressure and its term cancels out.
//
// Ping-pong pressure buffers: caller alternates pressure_in / pressure_out
// between iterations via two uniform sets. Race-free within a pass.
//
// Sanity: in a domain with uniform density ρ, this reduces to the classic
// uniform-density Jacobi up to a constant factor that's cancelled when the
// gradient shader divides by ρ. Single-substance pools behave identically
// to the uniform-density solver — only multi-substance mixes differ.

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

layout(set = 0, binding = 5, std430) restrict buffer CellDensity {
    float data[];
} cell_density;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

const float MIN_DENSITY = 0.0012;

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

    float rho_c = max(cell_density.data[idx], MIN_DENSITY);
    float inv_rho_c = 1.0 / rho_c;

    float num = 0.0;
    float den = 0.0;

    // Left neighbor
    if (x > 0) {
        int nidx = idx - 1;
        int ct = cell_type.data[nidx];
        if (ct == CELL_FLUID) {
            float rho_n = max(cell_density.data[nidx], MIN_DENSITY);
            float inv_rho_face = (inv_rho_c + 1.0 / rho_n) * 0.5;
            num += inv_rho_face * pressure_in.data[nidx];
            den += inv_rho_face;
        } else if (ct == CELL_AIR) {
            // Free surface: p_air = 0, use our own 1/ρ as the face weight.
            den += inv_rho_c;
        }
        // CELL_WALL: skip — zero-gradient BC, no contribution.
    }
    // Right neighbor
    if (x + 1 < w) {
        int nidx = idx + 1;
        int ct = cell_type.data[nidx];
        if (ct == CELL_FLUID) {
            float rho_n = max(cell_density.data[nidx], MIN_DENSITY);
            float inv_rho_face = (inv_rho_c + 1.0 / rho_n) * 0.5;
            num += inv_rho_face * pressure_in.data[nidx];
            den += inv_rho_face;
        } else if (ct == CELL_AIR) {
            den += inv_rho_c;
        }
    }
    // Top neighbor (y - 1)
    if (y > 0) {
        int nidx = idx - w;
        int ct = cell_type.data[nidx];
        if (ct == CELL_FLUID) {
            float rho_n = max(cell_density.data[nidx], MIN_DENSITY);
            float inv_rho_face = (inv_rho_c + 1.0 / rho_n) * 0.5;
            num += inv_rho_face * pressure_in.data[nidx];
            den += inv_rho_face;
        } else if (ct == CELL_AIR) {
            den += inv_rho_c;
        }
    }
    // Bottom neighbor (y + 1)
    if (y + 1 < h) {
        int nidx = idx + w;
        int ct = cell_type.data[nidx];
        if (ct == CELL_FLUID) {
            float rho_n = max(cell_density.data[nidx], MIN_DENSITY);
            float inv_rho_face = (inv_rho_c + 1.0 / rho_n) * 0.5;
            num += inv_rho_face * pressure_in.data[nidx];
            den += inv_rho_face;
        } else if (ct == CELL_AIR) {
            den += inv_rho_c;
        }
    }

    float div = divergence.data[idx];
    if (den > 0.0) {
        pressure_out.data[idx] = (num - div) / den;
    } else {
        // Fluid cell surrounded by walls on all sides — no pressure
        // constraint can be enforced, clamp to zero.
        pressure_out.data[idx] = 0.0;
    }
}
