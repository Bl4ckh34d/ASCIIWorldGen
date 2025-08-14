#[compute]
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) buffer FlowDirBuf { int flow_dir[]; } Flow;
layout(std430, set = 0, binding = 1) buffer FrontierInBuf { uint frontier_in[]; } Fin;
layout(std430, set = 0, binding = 2) buffer TotalBuf { uint total[]; } Total; // read/write
layout(std430, set = 0, binding = 3) buffer FrontierOutBuf { uint frontier_out[]; } Fout; // write accum

layout(push_constant) uniform Params {
    int total_cells; // full grid size
    int roi_x0;
    int roi_y0;
    int roi_x1;
    int roi_y1;
    int width;
} PC;

void main(){
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(PC.total_cells)) return;
    // ROI: reject indices that map outside the tile by reconstructing x,y
    int x = int(i % uint(PC.width));
    int y = int(i / uint(PC.width));
    if (x < PC.roi_x0 || x >= PC.roi_x1 || y < PC.roi_y0 || y >= PC.roi_y1) {
        return;
    }
    uint amount = Fin.frontier_in[i];
    if (amount == 0u) return;
    int to = Flow.flow_dir[i];
    if (to >= 0 && to < PC.total_cells) {
        atomicAdd(Fout.frontier_out[to], amount);
        atomicAdd(Total.total[to], amount);
    }
}


