#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int grid_width;
    int grid_height;
    float delta_time;
    int frame_count;
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellsBuffer {
    int data[];
} cells;

layout(set = 0, binding = 2, std430) restrict buffer BoundaryBuffer {
    int data[];
} boundary;

layout(set = 0, binding = 3, std430) restrict buffer TempsIn {
    float data[];
} temps_in;

layout(set = 0, binding = 4, std430) restrict buffer TempsOut {
    float data[];
} temps_out;

layout(set = 0, binding = 5, std430) restrict buffer SubstanceTable {
    float data[];
} substances;

const int STRIDE = 12;
const float AMBIENT_TEMP = 20.0;
const float AMBIENT_COOLING_RATE = 0.05;
const float CONDUCTION_RATE = 0.1;
const float RADIATION_RATE = 0.01;

float get_thermal_conductivity(int sub_id) {
    if (sub_id <= 0) return 0.0;
    return substances.data[sub_id * STRIDE + 2];
}

void main() {
    uint x = gl_GlobalInvocationID.x;
    uint y = gl_GlobalInvocationID.y;
    int w = params.grid_width;
    int h = params.grid_height;

    if (x >= uint(w) || y >= uint(h)) return;

    uint idx = y * uint(w) + x;
    if (boundary.data[idx] != 1) return;

    int sub_id = cells.data[idx];
    float temp = temps_in.data[idx];
    bool has_substance = sub_id > 0;

    // Temperature diffusion
    float conductivity = RADIATION_RATE;
    if (has_substance) {
        conductivity = get_thermal_conductivity(sub_id) * CONDUCTION_RATE;
    }

    float new_temp = temp;

    // 4-neighbor heat diffusion
    if (x > 0u && boundary.data[idx - 1u] == 1) {
        new_temp += (temps_in.data[idx - 1u] - temp) * conductivity * 0.25;
    }
    if (x < uint(w - 1) && boundary.data[idx + 1u] == 1) {
        new_temp += (temps_in.data[idx + 1u] - temp) * conductivity * 0.25;
    }
    if (y > 0u && boundary.data[idx - uint(w)] == 1) {
        new_temp += (temps_in.data[idx - uint(w)] - temp) * conductivity * 0.25;
    }
    if (y < uint(h - 1) && boundary.data[idx + uint(w)] == 1) {
        new_temp += (temps_in.data[idx + uint(w)] - temp) * conductivity * 0.25;
    }

    // Ambient cooling
    if (has_substance) {
        new_temp = mix(new_temp, AMBIENT_TEMP, AMBIENT_COOLING_RATE * 0.1);
    } else {
        new_temp = mix(new_temp, AMBIENT_TEMP, AMBIENT_COOLING_RATE);
    }

    temps_out.data[idx] = new_temp;
}
