#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>

#include <iostream>
#include <vector>

int const threadsPerBlock = sizeof(unsigned long long) * 8;

template <typename T>
__device__ inline bool devIoU(T const *const a, T const *const b,
                              const float threshold) {
  T left = max(a[0], b[0]), right = min(a[2], b[2]);
  T top = max(a[1], b[1]), bottom = min(a[3], b[3]);
  T width = max(right - left, (T)0), height = max(bottom - top, (T)0);
  T interS = width * height;
  T Sa = (a[2] - a[0]) * (a[3] - a[1]);
  T Sb = (b[2] - b[0]) * (b[3] - b[1]);
  return (interS / (Sa + Sb - interS)) > threshold;
}

template <typename integer>
constexpr __host__ __device__ inline integer ceil_div(integer n, integer m) {
  return (n + m - 1) / m;
}

template <typename T>
__global__ void nms_kernel(const int n_boxes, const float iou_threshold,
                           const T *dev_boxes, const int64_t *groups,
                           unsigned long long *dev_mask) {
  const int row_start = blockIdx.y;
  const int col_start = blockIdx.x;

  if (row_start > col_start)
    return;

  const int row_size =
      min(n_boxes - row_start * threadsPerBlock, threadsPerBlock);
  const int col_size =
      min(n_boxes - col_start * threadsPerBlock, threadsPerBlock);

  __shared__ T block_boxes[threadsPerBlock * 4];
  __shared__ int64_t block_groups[threadsPerBlock];
  if (threadIdx.x < col_size) {
    block_boxes[threadIdx.x * 4 + 0] =
        dev_boxes[(threadsPerBlock * col_start + threadIdx.x) * 4 + 0];
    block_boxes[threadIdx.x * 4 + 1] =
        dev_boxes[(threadsPerBlock * col_start + threadIdx.x) * 4 + 1];
    block_boxes[threadIdx.x * 4 + 2] =
        dev_boxes[(threadsPerBlock * col_start + threadIdx.x) * 4 + 2];
    block_boxes[threadIdx.x * 4 + 3] =
        dev_boxes[(threadsPerBlock * col_start + threadIdx.x) * 4 + 3];
    block_groups[threadIdx.x] =
        groups[threadsPerBlock * col_start + threadIdx.x];
  }
  __syncthreads();

  if (threadIdx.x < row_size) {
    const int cur_box_idx = threadsPerBlock * row_start + threadIdx.x;
    const T *cur_box = dev_boxes + cur_box_idx * 4;
    const int64_t cur_group = groups[cur_box_idx];
    int i = 0;
    unsigned long long t = 0;
    int start = 0;
    if (row_start == col_start) {
      start = threadIdx.x + 1;
    }
    for (i = start; i < col_size; i++) {
      if (cur_group == block_groups[i] &&
          devIoU<T>(cur_box, block_boxes + i * 4, iou_threshold)) {
        t |= 1ULL << i;
      }
    }
    const int col_blocks = ceil_div(n_boxes, threadsPerBlock);
    dev_mask[cur_box_idx * col_blocks + col_start] = t;
  }
}

at::Tensor nms_cuda(const at::Tensor &dets, const at::Tensor &scores,
                    const at::Tensor &groups, const double iou_threshold) {
  TORCH_CHECK(dets.is_cuda(), "dets must be a CUDA tensor");
  TORCH_CHECK(scores.is_cuda(), "scores must be a CUDA tensor");
  TORCH_CHECK(groups.is_cuda(), "groups must be a CUDA tensor");

  TORCH_CHECK(dets.dim() == 2, "boxes should be a 2d tensor, got ", dets.dim(),
              "D");
  TORCH_CHECK(dets.size(1) == 4,
              "boxes should have 4 elements in dimension 1, got ",
              dets.size(1));
  TORCH_CHECK(scores.dim() == 1, "scores should be a 1d tensor, got ",
              scores.dim(), "D");
  TORCH_CHECK(groups.dim() == 1, "groups should be a 1d tensor, got ",
              groups.dim(), "D");
  TORCH_CHECK(dets.size(0) == scores.size(0),
              "boxes and scores should have same number of elements in ",
              "dimension 0, got ", dets.size(0), " and ", scores.size(0))
  TORCH_CHECK(dets.size(0) == groups.size(0),
              "boxes and groups should have same number of elements in ",
              "dimension 0, got ", dets.size(0), " and ", groups.size(0))

  at::cuda::CUDAGuard device_guard(dets.device());

  if (dets.numel() == 0) {
    return at::empty({0}, dets.options().dtype(at::kLong));
  }

  auto order_t = std::get<1>(scores.sort(0, /* descending=*/true));
  auto dets_sorted = dets.index_select(0, order_t).contiguous();
  auto groups_sorted = groups.index_select(0, order_t).contiguous();

  int dets_num = dets.size(0);

  const int col_blocks = ceil_div(dets_num, threadsPerBlock);

  at::Tensor mask =
      at::empty({dets_num * col_blocks}, dets.options().dtype(at::kLong));

  dim3 blocks(col_blocks, col_blocks);
  dim3 threads(threadsPerBlock);
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(
      dets_sorted.scalar_type(), "nms_kernel_cuda", [&] {
        nms_kernel<scalar_t><<<blocks, threads, 0, stream>>>(
            dets_num, iou_threshold, dets_sorted.data_ptr<scalar_t>(),
            groups_sorted.data_ptr<int64_t>(),
            (unsigned long long *)mask.data_ptr<int64_t>());
      });

  at::Tensor mask_cpu = mask.to(at::kCPU);
  unsigned long long *mask_host =
      (unsigned long long *)mask_cpu.data_ptr<int64_t>();

  std::vector<unsigned long long> remv(col_blocks);
  memset(&remv[0], 0, sizeof(unsigned long long) * col_blocks);

  at::Tensor keep =
      at::empty({dets_num}, dets.options().dtype(at::kLong).device(at::kCPU));
  int64_t *keep_out = keep.data_ptr<int64_t>();

  int num_to_keep = 0;
  for (int i = 0; i < dets_num; i++) {
    int nblock = i / threadsPerBlock;
    int inblock = i % threadsPerBlock;

    if (!(remv[nblock] & (1ULL << inblock))) {
      keep_out[num_to_keep++] = i;
      unsigned long long *p = mask_host + i * col_blocks;
      for (int j = nblock; j < col_blocks; j++) {
        remv[j] |= p[j];
      }
    }
  }

  AT_CUDA_CHECK(cudaGetLastError());
  return order_t.index(
      {keep.narrow(/*dim=*/0, /*start=*/0, /*length=*/num_to_keep)
           .to(order_t.device(), keep.scalar_type())});
}

extern "C" {
void nms_cuda_ffi(at::Tensor **keep, at::Tensor *dets, at::Tensor *scores,
                  at::Tensor *groups, double iou_threshold) {
  at::Tensor keep_ = nms_cuda(*dets, *scores, *groups, iou_threshold);
  *keep = new at::Tensor(keep_);
}
}