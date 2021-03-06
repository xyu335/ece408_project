
#ifndef MXNET_OPERATOR_NEW_FORWARD_CUH_
#define MXNET_OPERATOR_NEW_FORWARD_CUH_

#include <mxnet/base.h>
#include <assert.h>

#define TILE_SIZE 16
#define CU_MAX_THREAD 1024

/* kernel buffer elelment size */
#define FAKE_K (5)
#define FAKE_M (10)
#define FAKE_C (20)
#define TOTAL_KERNEL_SIZE (FAKE_M * FAKE_K * FAKE_K * FAKE_C)

/* kernel size optimizaiton */
/* two layered network, first layer filter 5 * 5 * 6, second layer filter 5 * 5 * 16 */
#define TILE_SIZE_SMALL 22
#define TILE_SIZE_LARGE 20
#define FIRST_INPUT (1)
#define FIRST_OUTPUT (6)
#define SECOND_INPUT (6)
#define SECOND_OUTPUT (16)
#define KERNEL_WIDTH (5)
#define TOTAL_KERNEL_SIZE_LARGE (SECOND_INPUT * SECOND_OUTPUT * KERNEL_WIDTH * KERNEL_WIDTH)
#define TOTAL_KERNEL_SIZE_SMALL (FIRST_INPUT * FIRST_OUTPUT * KERNEL_WIDTH * KERNEL_WIDTH)

namespace mxnet
{
namespace op
{

/* kernel size opt*/ 
__constant__ float cons_mem_small[TOTAL_KERNEL_SIZE_SMALL];
__constant__ float cons_mem_large[TOTAL_KERNEL_SIZE_LARGE];
// __constant__ float cons_mem[TOTAL_KERNEL_SIZE];

__global__ void forward_kernel(float *y, const float *x, const float *k, const int B, const int M, const int C, const int H, const int W, const int K, const int W_grid)
{

    int b, m, h, w, c, p, q;
    b = blockIdx.x;
    m = blockIdx.y;
    h = blockIdx.z/W_grid*TILE_SIZE + threadIdx.y;
    w = blockIdx.z%W_grid*TILE_SIZE + threadIdx.x;
    float acc = 0.0f;
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;

#define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
#define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
#define k4d(i3, i2, i1, i0) k[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]

    if (h < H_out && w < W_out) {
        for (c = 0; c < C; ++c) {
            for (p = 0; p < K; ++p) {
                for (q = 0; q < K; ++q) {
                    acc += x4d(b, c, h + p, w + q)*k4d(m, c, p, q);
                }
            }
        }
        y4d(b, m, h, w) = acc;
    }

#undef y4d
#undef x4d
#undef k4d
}

__global__ void __gemm(float* A, float* B, float* C, int numARows, int numAColumns, int numBRows, int numBColumns, int numCRows, int numCColumns) {
    __shared__ float subTileM[TILE_SIZE][TILE_SIZE];
    __shared__ float subTileN[TILE_SIZE][TILE_SIZE];
    int bx = blockIdx.x; int by = blockIdx.y;
    int tx = threadIdx.x; int ty = threadIdx.y;
    int Row = by*TILE_SIZE + ty;
    int Col = bx*TILE_SIZE + tx;
    float Pvalue = 0.0f;

    for (int m = 0; m < ceil((float) numAColumns/TILE_SIZE); m++) {
        if (Row < numCRows && m*TILE_SIZE + tx < numAColumns)
            subTileM[ty][tx] = A[Row*numAColumns+m*TILE_SIZE+tx];
        else
            subTileM[ty][tx] = 0.0f;
        if (Col < numCColumns && m*TILE_SIZE + ty < numBRows)
            subTileN[ty][tx] = B[(m*TILE_SIZE + ty)*numBColumns+Col];
        else
            subTileN[ty][tx] = 0.0f;

        __syncthreads();
        for (int k = 0; k < TILE_SIZE; k++)
            Pvalue += subTileM[ty][k]*subTileN[k][tx];
        __syncthreads();
    }

    if (Row < numCRows && Col < numCColumns)
        C[Row*numCColumns+Col] = Pvalue;
}

__global__ void __unroll(int C, int H, int W, int K, float* X, float* X_unroll) {
    int t = blockIdx.x * CU_MAX_THREAD + threadIdx.x;
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;
    const int W_unroll = H_out*W_out;
    if (t < C*W_unroll) {
        int c = t / W_unroll;
        int s = t % W_unroll;
        int h_out = s / W_out;
        int w_out = s % W_out;
        int w_base = c * K * K;

        for (int p = 0; p < K; p++) {
            for (int q = 0; q < K; q++) {
                int h_unroll = w_base + p * K + q;
                X_unroll[h_unroll*W_unroll + s] = X[c*H*W + (h_out + p)*W + w_out + q];
            }
        }
    }
}


void gemm(float* A, float* B, float* C, int numARows, int numAColumns, int numBRows, int numBColumns, int numCRows, int numCColumns) {
    dim3 dimGrid(ceil((float) numCColumns/TILE_SIZE), ceil((float) numCRows/TILE_SIZE), 1);
    dim3 dimBlock(TILE_SIZE, TILE_SIZE, 1);
    __gemm<<<dimGrid, dimBlock>>>(A, B, C, numARows, numAColumns, numBRows, numBColumns, numCRows, numCColumns);
}

void unroll(int C, int H, int W, int K, float* X, float* X_unroll) {
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;
    const int num_threads = C*H_out*W_out;
    const int num_blocks = ceil(num_threads/ (CU_MAX_THREAD*1.0));
    dim3 dimGrid(num_blocks, 1, 1);
    dim3 dimBlock(CU_MAX_THREAD, 1, 1);
    __unroll<<<dimGrid, dimBlock>>>(C, H, W, K, X, X_unroll);
}

/* shared memory */
__global__ void forward_kernel_shmem(float *y, const float *x, const float *k,  const int H, const int W, const int M, const int C, const int K, const int W_grid)
{
  #define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
  #define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
  #define k4d(i3, i2, i1, i0) k[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]

  const int H_out = H - K + 1;
  const int W_out = W - K + 1;

  int n, m, h0, w0, h_base, w_base, h, w;
  int X_tile_width = TILE_SIZE + K - 1;

  extern __shared__ float shmem[];
  float * X_shared = &shmem[0];
  int k_start = X_tile_width * X_tile_width;
  float * K_shared = &shmem[k_start];

  n = blockIdx.x;
  m = blockIdx.y;
  h0 = threadIdx.x;
  w0 = threadIdx.y;
  h_base = blockIdx.z / W_grid * TILE_SIZE;
  w_base = blockIdx.z % W_grid * TILE_SIZE;
  h = h_base + h0;
  w = w_base + w0;

  float acc = 0.0f;

  int c, i, ii, j, p, pp, q;
  for (c = 0; c < C; c++) {
    if (h0 < K && w0 < K)
        K_shared[h0*K+w0] = k4d(m, c, h0, w0);
        __syncthreads();

        // thread block size should be TILF_WIDTH * TILE_SIZE, and the data may be reload here,
    for (i = h, ii = h0; i < h_base + X_tile_width; i += TILE_SIZE, ii += TILE_SIZE) {
      for (j = w; j < w_base + X_tile_width; j += TILE_SIZE) {
        X_shared[ii*X_tile_width+j-w_base] = x4d(n, c, i, j);
      }
    }
    __syncthreads();

    for (p = 0; p < K; p++) {
      for (q = 0; q < K; q++) {
        // acc += x2d_shmem(w0+p, h0+q) * k2d_shmem(p, q);
        acc += X_shared[(h0 + p)*X_tile_width + w0 + q] * K_shared[p*K + q];
      }
    }
  }
  if (h < H_out && w < W_out)
    y4d(n, m, h, w) = acc;

  #undef y4d
  #undef x4d
  #undef k4d
}

/* reduction tree  prototype */
// __global__ void forward_kernel_reduction_tree(float *y, const float *x, const float *k,  const int H, const int W, const int M, const int C, const int K, const int W_grid, char *lists)
// {
//   #define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
//   #define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
//   #define k4d(i3, i2, i1, i0) k[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]
//   #define shmem(i2, i1, i0) lists[]
//
//   const int H_out = H - K + 1;
//   const int W_out = W - K + 1;
//
//   int n, m, h0, w0, h_base, w_base, h, w;
//   int X_tile_width = TILE_SIZE + K - 1;
//
//   extern __shared__ float shmem[];
//   float * X_shared = &shmem[0];
//   int k_start = X_tile_width * X_tile_width;
//   float * K_shared = &shmem[k_start];
//
//   n = blockIdx.x;
//   m = blockIdx.y;
//   h0 = threadIdx.x;
//   w0 = threadIdx.y;
//   h_base = blockIdx.z / W_grid * TILE_SIZE;
//   w_base = blockIdx.z % W_grid * TILE_SIZE;
//   h = h_base + h0;
//   w = w_base + w0;
//
//   float acc = 0.0f;
//
//   int c, i, ii, j, p, pp, q;
//   for (c = 0; c < C; c++) {
//     if (h0 < K && w0 < K)
//         K_shared[h0*K+w0] = k4d(m, c, h0, w0);
//         __syncthreads();
//
//         // thread block size should be TILF_WIDTH * TILE_SIZE, and the data may be reload here,
//     for (i = h, ii = h0; i < h_base + X_tile_width; i += TILE_SIZE, ii += TILE_SIZE) {
//       for (j = w; j < w_base + X_tile_width; j += TILE_SIZE) {
//         X_shared[ii*X_tile_width+j-w_base] = x4d(n, c, i, j);
//       }
//     }
//     __syncthreads();
//
//     for (p = 0; p < K; p++) {
//       for (q = 0; q < K; q++) {
//         // acc += x2d_shmem(w0+p, h0+q) * k2d_shmem(p, q);
//         acc += X_shared[(h0 + p)*X_tile_width + w0 + q] * K_shared[p*K + q];
//       }
//     }
//     shmem(tx, h, w) = acc;
//   }
//   if (h < H_out && w < W_out)
//     y4d(n, m, h, w) = acc;
//
//   #undef y4d
//   #undef x4d
//   #undef k4d
// }
//
// __global__ void total(float *input, float *output, int len) {
//   unsigned int t = threadIdx.x;
//   unsigned int start = 2 * blockDim.x * blockIdx.x;
//
//   //@@ Load a segment of the input vector into shared memory
//   __shared__ float partialSum[2 * BLOCK_SIZE];
//   if (start + t < len)
//     partialSum[t] = input[start + t];
//   else
//     partialSum[t] = 0;
//   if (blockDim.x + start + t < len)
//     partialSum[blockDim.x + t] = input[blockDim.x + start + t];
//   else
//     partialSum[blockDim.x + t] = 0;
//
//   //@@ Traverse the reduction tree
//   for (unsigned int stride = blockDim.x; stride >= 1; stride >>= 1) {
//     __syncthreads();
//     if (t < stride)
//       partialSum[t] += partialSum[t + stride];
//   }

// __global__ void forward_kernel_reduction_tree(float *y, const float *x, const float *k, const int B, const int M, const int C, const int H, const int W, const int K, const int W_grid)
// {
//
//     int b, m, h, w, c, p, q, tx, h_base, w_base;
//     b = blockIdx.x;
//     m = blockIdx.y;
//     h_base = blockIdx.z/W_grid*TILE_SIZE;
//     w_base = blockIdx.z%W_grid*TILE_SIZE;
//
//     float acc = 0.0f;
//     const int H_out = H - K + 1;
//     const int W_out = W - K + 1;
//         tx = threadIdx.x;
//
// #define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
// #define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
// #define k4d(i3, i2, i1, i0) k[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]
// #define shmem(i2, i1, i0) ... // TODO
//
//         extern __shared__ float shmem[]; // shmem[C][TILE_SIZE][TILE_SIZE]; // temp declaration
//         int stride = blockDim.x / 2;
//
//         for (int dh = 0; dh < TILE_SIZE; ++dh)
//         {
//             for (int dw = 0; dw < TILE_SIZE; ++dw)
//             {
//                 if (h_base + dh < H_out && w_base + dw < W_out)
//                 {
//                     float acc = 0.0f;
//           for (p = 0; p < K; ++p) {
//             for (q = 0; q < K; ++q) {
//               acc += x4d(b, c, h + p, w + q)*k4d(m, tx, p, q);
//             }
//           }
//           shmem[tx, h, w] = acc;
//                 }
//             }
//         }
//
//         for (int std = stride/2; std > 0; std /= 2)
//         {
//             if (tx < std)
//             {
//                 float sum = 0.0f;
//                 for (int p = 0; p < TILE_SIZE; ++p)
//                 {
//                     for (int q = 0; q < TILE_SIZE; ++q)
//                     {
//                         shmem[tx, p, q] += shmem[tx+std, p, q];  // TODO shmem macro taking 3 inputs
//                     }
//                 }
//             }
//             __syncthreads();
//
//         }
//
//     if (tx == 0) {
//             for (int ho = 0; ho < TILE_SIZE; ++ho)
//             {
//                 for (int wo = 0; wo < TILE_SIZE; ++wo)
//                 {
//     			y4d(b, w, ho + h_base, wo + w_base) = shmem[tx, ho + h_base, wo + w_base];
//                 }
//             }
//     }
//
// #undef shmem
// #undef y4d
// #undef x4d
// #undef k4d
// }



/* constant memory optimization */
__global__ void forward_kernel_consmem(float *y, const float *x, const int B, const int M, const int C, const int H, const int W, const int K, const int W_grid)
{
    int b, m, h, w, c, p, q;
    b = blockIdx.x;
    m = blockIdx.y;
    h = blockIdx.z/W_grid*TILE_SIZE + threadIdx.y;
    w = blockIdx.z%W_grid*TILE_SIZE + threadIdx.x;
    float acc = 0.0f;
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;

#define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
#define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
#define k4d_constant(i3, i2, i1, i0) cons_mem[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]

    if (h < H_out && w < W_out) {
        for (c = 0; c < C; ++c) {
            for (p = 0; p < K; ++p) {
                for (q = 0; q < K; ++q) {
                  // acc += x4d(b, c, h + p, w + q) * k4d_constant(m, c, p, q);
                }
            }
        }
        y4d(b, m, h, w) = acc;
    }

#undef y4d
#undef x4d
#undef k4d_constant
}

#define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
#define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
#define k4d_constant_large(i3, i2, i1, i0) cons_mem_large[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]
#define k4d_constant_small(i3, i2, i1, i0) cons_mem_small[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]
/* different kernel implementation(parameters) */
__global__ void forward_kernel_consmem_large(float *y, const float *x, const int B, const int M, const int C, const int H, const int W, const int K, const int W_grid)
{
    /*
    Modify this function to implement the forward pass described in Chapter 16.
    We have added an additional dimension to the tensors to support an entire mini-batch
    The goal here is to be correct AND fast.
    We have some nice #defs for you below to simplify indexing. Feel free to use them, or create your own.
    */
    int b, m, h, w, c, p, q;
    b = blockIdx.x;
    m = blockIdx.y;
    h = blockIdx.z/W_grid*TILE_SIZE_LARGE + threadIdx.y;
    w = blockIdx.z%W_grid*TILE_SIZE_LARGE + threadIdx.x;
    float acc = 0.0f;
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;

    if (h < H_out && w < W_out) {
        for (c = 0; c < C; ++c) {
            for (p = 0; p < K; ++p) {
                for (q = 0; q < K; ++q) { 
                  acc += x4d(b, c, h + p, w + q) * k4d_constant_large(m, c, p, q);
                }
            }
        }
        y4d(b, m, h, w) = acc;
    }

}
__global__ void forward_kernel_consmem_small(float *y, const float *x, const int B, const int M, const int C, const int H, const int W, const int K, const int W_grid)
{
    int b, m, h, w, c, p, q;
    b = blockIdx.x;
    m = blockIdx.y;
    h = blockIdx.z/W_grid*TILE_SIZE_SMALL + threadIdx.y;
    w = blockIdx.z%W_grid*TILE_SIZE_SMALL + threadIdx.x;
    float acc = 0.0f;
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;
    if (h < H_out && w < W_out) {
        for (c = 0; c < C; ++c) {
            for (p = 0; p < K; ++p) {
                for (q = 0; q < K; ++q) { 
                  acc += x4d(b, c, h + p, w + q) * k4d_constant_small(m, c, p, q);
                }
            }
        }
        y4d(b, m, h, w) = acc;
    }

}
#undef y4d
#undef x4d
#undef k4d_constant_large
#undef k4d_constant_small

/*
   This function is called by new-inl.h
   Any code you write should be executed by this function.
   For ECE408, we only expect the float version of the operator to be called, so here we specialize with only floats.
*/
template <>
void forward<gpu, float>(mshadow::Tensor<gpu, 4, float> &y, const mshadow::Tensor<gpu, 4, float> &x, const mshadow::Tensor<gpu, 4, float> &w)
{
    const int B = x.shape_[0]; // batch_size
    const int C = x.shape_[1]; // in_channels
    const int H = x.shape_[2]; // height
    const int W = x.shape_[3]; // weight
    const int M = y.shape_[1]; // out_channels
    const int K = w.shape_[3]; // kernel_size
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;
    const int W_unroll = C*K*K;
    const int H_unroll = H_out*W_out;

    /* unroll optimization */

/*
    float* X_unrolled;
    cudaMalloc(&X_unrolled, W_unroll*H_unroll*sizeof(float));

    #pragma unroll
    for (int b = 0; b < B; b++) {
        float* x_dptr = &x.dptr_[b*C*H*W];
        unroll(C, H, W, K, x_dptr, X_unrolled);
        float* y_dptr = &y.dptr_[b*M*H_unroll];
        gemm(w.dptr_, X_unrolled, y_dptr, M, W_unroll, W_unroll, H_unroll, M, H_unroll);
    }
    cudaFree(X_unrolled);
*/

	/*
  const int H_grid = ceil((float)H_out / TILE_SIZE);
  const int W_grid = ceil((float) W_out / TILE_SIZE);
  const int Z =  H_grid * W_grid;

  dim3 gridDim(B, M, Z);
  dim3 blockDim(TILE_SIZE, TILE_SIZE, 1);
	*/

  /*  shared memory optimization */
	/*  
	size_t shmem_size = sizeof(float)  * ((TILE_SIZE + K - 1) * (TILE_SIZE + K -1 ) + K * K);
  forward_kernel_shmem<<<gridDim, blockDim, shmem_size>>>(y.dptr_, x.dptr_, w.dptr_, H, W, M, C, K, W_grid);
	*/

/* reduction tree optimization, invocation prototype */
  // float *lists;
  // cudaMalloc((void **)&lists, C * M * H_grid * W_grid * sizeof(float));
  // size_t shmem_size = sizeof(float)  * ((TILE_SIZE + K - 1) * (TILE_SIZE + K -1 ) + K * K);
  // forward_kernel_shmem<<<gridDim, blockDim, shmem_size>>>(y.dptr_, x.dptr_, w.dptr_, H, W, M, C, K, W_grid, lists);

/*
dim3 blockDim(C, 1, 1); // each block has all channel of input image
dim3 gridDim(B, M, Z); //
size_t shmem_size = sizeof(float) * TILE_WIDTH * TILE_WIDTH * CU_MAX_THREAD;
forward_kernel<<<gridDim, blockDim, shmem_size>>>(y.dptr_,x.dptr_,w.dptr_, B,M,C,H,W,K,W_grid);
*/


    /* constant memory optimization */
    // int TRUE_KERNEL_SIZE = K * K * M * C;
    // cudaMemcpyToSymbol(cons_mem, w.dptr_, sizeof(float) * TRUE_KERNEL_SIZE);
    // forward_kernel_consmem<<<gridDim, blockDim>>>(y.dptr_, x.dptr_, B, M, C, H, W, K, W_grid);

		/* two kernel implementation */
		size_t ksize = 0;
		size_t tile_size = 0;
		if(M == SECOND_OUTPUT) tile_size = TILE_SIZE_LARGE;
		else tile_size = TILE_SIZE_SMALL;

		const int H_grid = ceil((float)H_out / tile_size);
		const int W_grid = ceil((float) W_out / tile_size);
		const int Z =  H_grid * W_grid;
		dim3 gridDim(B, M, Z);
		dim3 blockDim(tile_size, tile_size, 1);

    if(M == SECOND_OUTPUT)
    {
      ksize = TOTAL_KERNEL_SIZE_LARGE * sizeof(float);
      cudaMemcpyToSymbol(cons_mem_large, w.dptr_, ksize);
      forward_kernel_consmem_large<<<gridDim, blockDim>>>(y.dptr_, x.dptr_, B, M, C, H, W, K, W_grid);
    }
    if(M == FIRST_OUTPUT)
    { 
      assert(M == FIRST_OUTPUT);
      ksize = TOTAL_KERNEL_SIZE_SMALL * sizeof(float);
      cudaMemcpyToSymbol(cons_mem_small, w.dptr_, ksize);
      forward_kernel_consmem_small<<<gridDim, blockDim>>>(y.dptr_, x.dptr_, B, M, C, H, W, K, W_grid);
    }

    // Use MSHADOW_CUDA_CALL to check for CUDA runtime errors.
    MSHADOW_CUDA_CALL(cudaDeviceSynchronize());

}

/*
    This tells mxnet how to do an op when it's not a float.
    This is not used in the ECE408 project
*/
template <typename gpu, typename DType>
void forward(mshadow::Tensor<gpu, 4, DType> &y, const mshadow::Tensor<gpu, 4, DType> &x, const mshadow::Tensor<gpu, 4, DType> &w)
{
    CHECK_EQ(0,1) << "Remove this line and replace it with your implementation.";
}
}
}

#undef TILE_SIZE

#endif
