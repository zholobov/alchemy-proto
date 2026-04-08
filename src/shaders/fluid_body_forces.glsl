#[compute]
#version 450

// Apply body forces (gravity + buoyancy) to the VaporSim v-velocity field.
//
// Physics: Archimedes' principle. The effective vertical acceleration on
// a parcel of fluid of density ρ in an ambient fluid of density ρ_a is
//
//     a = g × (1 - ρ_a / ρ)
//
// When ρ > ρ_a: a is positive (sinks). Heavy gases (CO2, chlorine) sink.
// When ρ = ρ_a: a is zero (neutral buoyancy, hovers).
// When ρ < ρ_a: a is negative (rises). Steam, hot air, methane rise.
//
// For VaporSim the ambient is air, AIR_DENSITY ≈ 0.0012 in our normalized
// scale (water = 1.0). Each gas substance's density is read from the
// substance_props table, indexed by the per-cell substance id.

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

layout(set = 0, binding = 3, std430) restrict buffer SubstanceBuffer {
    int data[];
} substance;

layout(set = 0, binding = 4, std430) restrict buffer SubstanceProperties {
    // vec4 per substance id. .x = viscosity, .y = flip_ratio, .z = density,
    // .w = reserved. VaporSim uses .z for buoyancy.
    vec4 data[];
} substance_props;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

// Base gravity magnitude before buoyancy scaling. Cells/sec^2 in grid units.
const float BASE_GRAVITY = 20.0;

// Ambient density for buoyancy calculation. In our normalized scale
// (water = 1.0), air ≈ 0.0012. A substance with density below this rises,
// above this sinks.
const float AIR_DENSITY = 0.0012;


int v_idx(int x, int y, int w) {
    return y * w + x;
}

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= w || y >= h) return;

    // Each cell is responsible for its TOP v-face at v_idx(x, y), which is
    // the face between cell (x, y-1) above and cell (x, y) below. Every
    // interior v-face gets processed exactly once.
    int bot_idx = y * w + x;
    int top_idx = (y > 0) ? (y - 1) * w + x : -1;

    int bot_ct = cell_type.data[bot_idx];
    int top_ct = (top_idx >= 0) ? cell_type.data[top_idx] : CELL_AIR;

    bool any_wall = (bot_ct == CELL_WALL) || (top_ct == CELL_WALL);
    if (any_wall) return;

    // Pick the substance id for this face. Prefer the bottom cell's
    // substance if it's fluid (most common case: gas rising from below),
    // fall back to the top cell.
    int face_sub = 0;
    if (bot_ct == CELL_FLUID) {
        face_sub = substance.data[bot_idx];
    } else if (top_ct == CELL_FLUID && top_idx >= 0) {
        face_sub = substance.data[top_idx];
    } else {
        return;  // face not bordered by any fluid cell — skip
    }

    if (face_sub <= 0) return;

    // Density-based buoyancy. If density is 0 or negative (uninitialized
    // substance slot, or a substance missing the property), fall back to
    // plain downward gravity.
    float density = substance_props.data[face_sub].z;
    float effective_g;
    if (density > 0.0) {
        effective_g = BASE_GRAVITY * (1.0 - AIR_DENSITY / density);
    } else {
        effective_g = BASE_GRAVITY;
    }

    v_vel.data[v_idx(x, y, w)] += effective_g * params.delta_time;
}
