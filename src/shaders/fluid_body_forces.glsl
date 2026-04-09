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

layout(set = 0, binding = 5, std430) restrict buffer AmbientDensity {
    // Per-cell ambient density uploaded by Receptacle.compute_ambient_density.
    // Heavier phase wins: a cell with water present reads as water density,
    // a cell with only vapor reads vapor density, an empty cell reads AIR.
    // Lets this shader do cross-phase buoyancy — vapor rising in liquid
    // sees ambient ≈ 1.0 and gets a huge upward push.
    float data[];
} ambient_density;

layout(set = 0, binding = 6, std430) restrict buffer Temperature {
    // Per-cell temperature (°C) for thermal buoyancy. Hot gas becomes
    // effectively lighter and rises via Archimedes.
    float data[];
} temperature;

const int CELL_AIR = 0;
const int CELL_FLUID = 1;
const int CELL_WALL = 2;

// Base gravity magnitude before buoyancy scaling. Cells/sec^2 in grid units.
const float BASE_GRAVITY = 20.0;

// Fallback air density if the ambient field isn't populated yet.
const float AIR_DENSITY = 0.0012;

// Thermal expansion tuning (25x exaggerated compared to real water/air so
// convection is visually obvious over a small 200x150 grid).
const float THERMAL_EXPANSION = 0.005;
const float REFERENCE_TEMP = 20.0;


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

    // Phase-interface buoyancy. Default is full downward gravity so a
    // uniform gas cloud in empty air still gets some gravity pull. Apply
    // Archimedes only when neighbors have a significantly different
    // density (from another phase or a temperature gradient). This
    // matches the pflip_advect formulation and avoids the homogeneous
    // cloud "floats at zero g" bug.
    const float PHASE_INTERFACE_THRESHOLD = 0.05;

    int fluid_cell_idx = (bot_ct == CELL_FLUID) ? bot_idx : top_idx;
    int fcx = fluid_cell_idx % w;
    int fcy = fluid_cell_idx / w;

    // Apply thermal modulation to the gas's density: hot gas is lighter.
    float density = substance_props.data[face_sub].z;
    float cell_temp = temperature.data[fluid_cell_idx];
    float thermal_factor = 1.0 - THERMAL_EXPANSION * (cell_temp - REFERENCE_TEMP);
    thermal_factor = clamp(thermal_factor, 0.1, 2.0);
    density *= thermal_factor;

    // Scan 3x3 neighbors for cells with significantly different density.
    float external_sum = 0.0;
    int external_count = 0;
    for (int ddy = -1; ddy <= 1; ddy++) {
        for (int ddx = -1; ddx <= 1; ddx++) {
            int nx = fcx + ddx;
            int ny = fcy + ddy;
            if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
            float n_density = ambient_density.data[ny * w + nx];
            float rel_diff = abs(n_density - density) / max(density, 0.0001);
            if (rel_diff > PHASE_INTERFACE_THRESHOLD) {
                external_sum += n_density;
                external_count++;
            }
        }
    }

    float effective_g = BASE_GRAVITY;
    if (external_count > 0 && density > 0.0) {
        // At a phase interface — apply Archimedes with the external cells
        // as ambient. A gas bubble in water sees water ambient and rises;
        // a heavy gas in lighter gas sees the lighter as ambient and sinks.
        float ambient = external_sum / float(external_count);
        effective_g = BASE_GRAVITY * (1.0 - ambient / density);
        effective_g = max(effective_g, -3.0 * BASE_GRAVITY);
    }

    v_vel.data[v_idx(x, y, w)] += effective_g * params.delta_time;
}
