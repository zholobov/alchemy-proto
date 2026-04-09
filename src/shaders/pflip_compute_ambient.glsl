#[compute]
#version 450

// Per-cell ambient density from the substance buffer. For each cell,
// reads the substance id (from p2g last-writer-wins), looks up its
// density in the substance_props table, and applies thermal modulation.
// Written to buf_ambient_density which pflip_advect samples for
// Archimedes buoyancy.
//
// Runs per substep (inside the compute list, before advect) so ambient
// density is fresh for every substep's buoyancy calculation. Replaces
// the CPU-side compute_ambient_density() which only ran once per frame.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int extra;
} params;

layout(set = 0, binding = 1, std430) restrict buffer Substance {
    int data[];
} substance;

layout(set = 0, binding = 2, std430) restrict buffer SubstanceProperties {
    vec4 data[];  // .z = density
} substance_props;

layout(set = 0, binding = 3, std430) restrict buffer Temperature {
    float data[];
} temperature;

layout(set = 0, binding = 4, std430) restrict buffer AmbientDensity {
    float data[];
} ambient_density;

const float AIR_DENSITY = 0.0012;
const float THERMAL_EXPANSION = 0.005;
const float REFERENCE_TEMP = 20.0;

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    int w = params.grid_width;
    int h = params.grid_height;
    if (x >= w || y >= h) return;

    int idx = y * w + x;
    int sid = substance.data[idx];
    float rho = AIR_DENSITY;
    if (sid > 0) {
        rho = substance_props.data[sid].z;
    }

    // Thermal modulation — must match pflip_advect.glsl and
    // receptacle.gd THERMAL_EXPANSION so self and ambient use
    // the same temperature-driven scaling.
    float temp = temperature.data[idx];
    float thermal = 1.0 - THERMAL_EXPANSION * (temp - REFERENCE_TEMP);
    thermal = clamp(thermal, 0.1, 2.0);
    rho *= thermal;

    ambient_density.data[idx] = rho;
}
