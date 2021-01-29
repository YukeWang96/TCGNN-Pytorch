#include <torch/extension.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>

#include <vector>
#define MAX_DIM 100
#define MAX_NB 100       // must <= partsize 
#define threadPerWarp 2 //must < 32
#define wrapPerBlock 1  // must also set with respect to the 
                        // [thread-per-block = wrapPerBlock *  threadPerWarp]

__device__ inline float atomicAdd_F(float* address, float value)
{
  float old = value;  
  while ((old = atomicExch(address, atomicExch(address, 0.0f)+old))!=0.0f);
}

template <typename scalar_t>
__global__ void spmm_forward_cuda_kernel(
    int num_nodes, 
    int dim,
    int num_parts,
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> input,
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> output,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> row_pointers, 
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> column_index,
    torch::PackedTensorAccessor32<float,1,torch::RestrictPtrTraits> degrees,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part_pointers,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part2Node
);

template <typename scalar_t>
__global__ void spmm_backward_cuda_kernel(
    int num_nodes, 
    int dim,
    int num_parts,
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> d_output,
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> d_input,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> row_pointers,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> column_index,
    torch::PackedTensorAccessor32<float,1,torch::RestrictPtrTraits> degrees,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part_pointers,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part2Node
);


////////////////////////////////////////////
//
// Foward Pass
//
////////////////////////////////////////////
std::vector<torch::Tensor> spmm_forward_cuda(
    int threadPerBlock,
    torch::Tensor input,
    torch::Tensor row_pointers,
    torch::Tensor column_index,
    torch::Tensor degrees,
    torch::Tensor part_pointers,
    torch::Tensor part2Node
) 
{
    auto output = torch::zeros_like(input);
    const int dim = input.size(1);
    const int num_nodes = input.size(0);
    const int num_parts = part2Node.size(0);
    const int blocks = (num_parts * 32  + threadPerBlock - 1) / threadPerBlock; 

    AT_DISPATCH_FLOATING_TYPES(input.type(), "spmm_cuda_forward", ([&] {
                                spmm_forward_cuda_kernel<scalar_t><<<blocks, threadPerBlock>>>(
                                    num_nodes, 
                                    dim,
                                    num_parts,
                                    input.packed_accessor32<scalar_t,2,torch::RestrictPtrTraits>(),
                                    output.packed_accessor32<scalar_t,2,torch::RestrictPtrTraits>(),
                                    row_pointers.packed_accessor32<int,1,torch::RestrictPtrTraits>(), 
                                    column_index.packed_accessor32<int,1,torch::RestrictPtrTraits>(),
                                    degrees.packed_accessor32<float,1,torch::RestrictPtrTraits>(),
                                    part_pointers.packed_accessor32<int,1,torch::RestrictPtrTraits>(), 
                                    part2Node.packed_accessor32<int,1,torch::RestrictPtrTraits>()
                                );
                            }));
    // check for error
    cudaError_t error = cudaGetLastError();
    if(error != cudaSuccess)
    {
        // print the CUDA error message and exit
        printf("CUDA error: %s\n", cudaGetErrorString(error));
        exit(-1);
    }
    
    return {output};
}

template <typename scalar_t>
__global__ void spmm_forward_cuda_kernel(
    int num_nodes, 
    int dim,
    int num_parts, 
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> input,
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> output,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> row_pointers, 
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> column_index,
    torch::PackedTensorAccessor32<float,1,torch::RestrictPtrTraits> degrees,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part_pointers,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part2Node
) {

    int tid =  blockIdx.x * blockDim.x + threadIdx.x;
    int warpId =  tid / 32;
    int block_warpID = threadIdx.x/32;
    int intraWarp_tid = tid % 32;

    if (warpId < num_parts && intraWarp_tid < threadPerWarp){

        __shared__  int partial_index[MAX_NB * wrapPerBlock];
        __shared__ float partial_results[MAX_DIM * wrapPerBlock];

        int srcId = part2Node[warpId];
        int partBeg = part_pointers[warpId];
        int partEnd = part_pointers[warpId + 1];
        float src_norm = degrees[srcId];

        int pindex_base = block_warpID * MAX_NB;
        for (int nid = partBeg + intraWarp_tid; nid < partEnd; nid += threadPerWarp){
            partial_index[pindex_base + nid - partBeg] = column_index[nid];
        }
         __syncthreads();

        int presult_base = block_warpID * MAX_DIM;
        for (int nid = 0; nid < partEnd - partBeg; nid++)
        {
            int nIndex = partial_index[pindex_base + nid];
            // float degree_norm_inv_td = degree_norm_inv[pindex_base + nid];
            // float degree_norm_inv = src_norm * dst_norm[pindex_base + nid];

            // float degree_norm_inv =  __fmaf_rn(src_norm, degrees[nIndex], 0);
            float degree_norm_inv = __fmaf_rn(src_norm, degrees[nIndex], 0);

            // float degree_norm_inv = 1.0/sqrt(degrees[srcId]) * (1.0/sqrt(degrees[nIndex]));
            // float degree_norm_inv = 1;
            if (nid == 0)
                for (int d = intraWarp_tid; d < dim; d += threadPerWarp){
                    partial_results[presult_base + d] = 0;
                }
            for (int d = intraWarp_tid; d < dim; d += threadPerWarp){
                partial_results[presult_base + d] += __fmaf_rn(degree_norm_inv, input[nIndex][d], 0);
            }
        }

        for (int d = intraWarp_tid; d < dim; d += threadPerWarp){
            atomicAdd_F((float*)&output[srcId][d], partial_results[presult_base + d]);
        }
    }
}

////////////////////////////////////////////
// 
// backward pass
//
////////////////////////////////////////////
std::vector<torch::Tensor> spmm_backward_cuda(
    int threadPerBlock,
    torch::Tensor d_output,
    torch::Tensor row_pointers,
    torch::Tensor column_index,
    torch::Tensor degrees,
    torch::Tensor part_pointers,
    torch::Tensor part2Node
) {

    auto d_input = torch::zeros_like(d_output);
    // d_input = d_output;
    const int dim = d_input.size(1);
    const int num_nodes = d_input.size(0);
    const int num_parts = part2Node.size(0);
    const int blocks = (num_parts * 32 + threadPerBlock - 1) / threadPerBlock; 

    AT_DISPATCH_FLOATING_TYPES(d_output.type(), "spmm_cuda_backward", ([&] {
                                spmm_backward_cuda_kernel<scalar_t><<<blocks, threadPerBlock>>>(
                                    num_nodes, 
                                    dim,
                                    num_parts,
                                    d_output.packed_accessor32<scalar_t,2,torch::RestrictPtrTraits>(),
                                    d_input.packed_accessor32<scalar_t,2,torch::RestrictPtrTraits>(),
                                    row_pointers.packed_accessor32<int,1,torch::RestrictPtrTraits>(),
                                    column_index.packed_accessor32<int,1,torch::RestrictPtrTraits>(),
                                    degrees.packed_accessor32<float,1,torch::RestrictPtrTraits>(),
                                    part_pointers.packed_accessor32<int,1,torch::RestrictPtrTraits>(), 
                                    part2Node.packed_accessor32<int,1,torch::RestrictPtrTraits>()
                                );
                            }));
    // check for error
    cudaError_t error = cudaGetLastError();
    if(error != cudaSuccess){
        printf("CUDA error: %s\n", cudaGetErrorString(error));
        exit(-1);
    }

    return {d_input};
}

template <typename scalar_t>
__global__ void spmm_backward_cuda_kernel(
    int num_nodes, 
    int dim,
    int num_parts, 
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> d_output,
    torch::PackedTensorAccessor32<scalar_t,2,torch::RestrictPtrTraits> d_input,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> row_pointers,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> column_index,
    torch::PackedTensorAccessor32<float,1,torch::RestrictPtrTraits> degrees,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part_pointers,
    torch::PackedTensorAccessor32<int,1,torch::RestrictPtrTraits> part2Node
) {

    int tid =  blockIdx.x * blockDim.x + threadIdx.x;
    int warpId =  tid / 32;
    int intraWarp_tid = tid % 32;
    int block_warpID = threadIdx.x/32;
    
    if (warpId < num_parts && intraWarp_tid < threadPerWarp){

        __shared__  int partial_index[MAX_NB * wrapPerBlock];
        __shared__ float partial_results[MAX_DIM * wrapPerBlock];

        int srcId = part2Node[warpId];
        int partBeg = part_pointers[warpId];
        int partEnd = part_pointers[warpId + 1];
        float src_norm = degrees[srcId];

        int pindex_base = block_warpID * MAX_NB;
        for (int nid = partBeg + intraWarp_tid; nid < partEnd; nid += threadPerWarp){
            partial_index[pindex_base + nid - partBeg] = column_index[nid];
        }
         __syncthreads();

        int presult_base = block_warpID * MAX_DIM;
        for (int nid = 0; nid < partEnd - partBeg; nid++)
        {
            int nIndex = partial_index[pindex_base + nid];
            float degree_norm =  __fmaf_rn(src_norm, degrees[nIndex], 0);

            if (nid == 0)
                for (int d = intraWarp_tid; d < dim; d += threadPerWarp){
                    partial_results[presult_base + d] = 0;
                    // atomicAdd_F((float*)&d_input[srcId][d], degree_norm * d_output[nIndex][d]);
                }
            for (int d = intraWarp_tid; d < dim; d += threadPerWarp){
                partial_results[presult_base + d] += __fmaf_rn(degree_norm, d_output[nIndex][d], 0);
            }
        }
        for (int d = intraWarp_tid; d < dim; d += threadPerWarp){
            atomicAdd_F((float*)&d_input[srcId][d], partial_results[presult_base + d]);
        }
    }
}
