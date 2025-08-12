#[compute]
#version 450

// Traces rivers by iteratively pushing along flow_dir from seeds; stops at ocean or lakes.
// Each iteration: frontier_in -> frontier_out by writing flags. Uses two ping-pong buffers.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer FlowDirBuf { int flow_dir[]; } Flow;
layout(std430, set = 0, binding = 1) buffer IsLandBuf { uint is_land[]; } Land;
layout(std430, set = 0, binding = 2) buffer LakeBuf { uint lake[]; } Lake;
layout(std430, set = 0, binding = 3) buffer FrontierInBuf { uint frontier_in[]; } Fin;
layout(std430, set = 0, binding = 4) buffer FrontierOutBuf { uint frontier_out[]; } Fout;
layout(std430, set = 0, binding = 5) buffer RiverBuf { uint river[]; } River; // write 1 where river present

layout(push_constant) uniform Params { int total_cells; } PC;

void main(){
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.total_cells)) return;
    if (Fin.frontier_in[i] == 0u) return;
    // mark current as river
    River.river[i] = 1u;
    int to = Flow.flow_dir[i];
    if (to < 0 || to >= PC.total_cells) return;
    if (Land.is_land[to] == 0u || Lake.lake[to] != 0u) return; // stop at ocean or lakes
    atomicAdd(Fout.frontier_out[to], 1u);
}


