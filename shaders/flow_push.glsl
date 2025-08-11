// File: res://shaders/flow_push.glsl
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer FlowDirBuf { int flow_dir[]; } Flow;
layout(set = 0, binding = 1, std430) readonly buffer FrontierInBuf { uint frontier_in[]; } Fin;
layout(set = 0, binding = 2, std430) buffer TotalBuf { uint total[]; } Total; // read/write
layout(set = 0, binding = 3, std430) buffer FrontierOutBuf { uint frontier_out[]; } Fout; // write accum

layout(push_constant) uniform Params { int total_cells; } PC;

void main(){
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.total_cells)) return;
    uint amount = Fin.frontier_in[i];
    if (amount == 0u) return;
    int to = Flow.flow_dir[i];
    if (to >= 0 && to < PC.total_cells) {
        atomicAdd(Fout.frontier_out[to], amount);
        atomicAdd(Total.total[to], amount);
    }
}


