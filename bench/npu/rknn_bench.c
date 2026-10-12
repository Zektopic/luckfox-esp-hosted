// NPU benchmark for the Luckfox Pico (RV1106, librknnmrt 1.6.0).
//   rknn_bench <model.rknn> [runs=100] [warmup=5] [seconds=0]
// seconds > 0: run for that long instead of a fixed count (for the combined NPU + encoder test).
// Uses the zero-copy API the RV1106 runtime requires (rknn_create_mem + rknn_set_io_mem, NHWC uint8
// input) like Luckfox's yolov5 example. Input is a fixed pseudo-random image: timing doesn't depend on it.
// Prints per-run wall latency (avg/min/p50/p95/max) and the runtime's memory report
// (RKNN_QUERY_MEM_SIZE: weights, internal, total DMA). RKNN_QUERY_PERF_RUN isn't supported by this runtime.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "rknn_api.h"

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <model.rknn> [runs=100] [warmup=5] [seconds=0]\n", argv[0]);
        return 1;
    }
    const char *model = argv[1];
    int runs = argc > 2 ? atoi(argv[2]) : 100;
    int warmup = argc > 3 ? atoi(argv[3]) : 5;
    double seconds = argc > 4 ? atof(argv[4]) : 0;

    rknn_context ctx = 0;
    double t0 = now_ms();
    int ret = rknn_init(&ctx, (void *)model, 0, 0, NULL);
    double init_ms = now_ms() - t0;
    if (ret < 0) {
        fprintf(stderr, "rknn_init failed: %d\n", ret);
        return 1;
    }

    rknn_sdk_version ver;
    if (rknn_query(ctx, RKNN_QUERY_SDK_VERSION, &ver, sizeof(ver)) == 0)
        printf("sdk %s, driver %s\n", ver.api_version, ver.drv_version);

    rknn_input_output_num io;
    rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io, sizeof(io));

    rknn_tensor_attr in_attr;
    memset(&in_attr, 0, sizeof(in_attr));
    in_attr.index = 0;
    rknn_query(ctx, RKNN_QUERY_NATIVE_INPUT_ATTR, &in_attr, sizeof(in_attr));
    printf("input: %s dims=[%d,%d,%d,%d] size_with_stride=%u, %u outputs\n", in_attr.name,
           in_attr.dims[0], in_attr.dims[1], in_attr.dims[2], in_attr.dims[3], in_attr.size_with_stride, io.n_output);

    // uint8 NHWC input (the only zero-copy input format on RV1106)
    in_attr.type = RKNN_TENSOR_UINT8;
    in_attr.fmt = RKNN_TENSOR_NHWC;
    rknn_tensor_mem *in_mem = rknn_create_mem(ctx, in_attr.size_with_stride);
    if (!in_mem || rknn_set_io_mem(ctx, in_mem, &in_attr) < 0) {
        fprintf(stderr, "input mem setup failed\n");
        return 1;
    }
    unsigned seed = 12345;
    for (uint32_t i = 0; i < in_attr.size_with_stride; i++) {
        seed = seed * 1103515245u + 12345u;
        ((unsigned char *)in_mem->virt_addr)[i] = seed >> 24;
    }

    rknn_tensor_mem **out_mem = calloc(io.n_output, sizeof(*out_mem));
    for (uint32_t i = 0; i < io.n_output; i++) {
        rknn_tensor_attr a;
        memset(&a, 0, sizeof(a));
        a.index = i;
        rknn_query(ctx, RKNN_QUERY_NATIVE_NHWC_OUTPUT_ATTR, &a, sizeof(a));
        out_mem[i] = rknn_create_mem(ctx, a.size_with_stride);
        if (!out_mem[i] || rknn_set_io_mem(ctx, out_mem[i], &a) < 0) {
            fprintf(stderr, "output %u mem setup failed\n", i);
            return 1;
        }
    }

    for (int i = 0; i < warmup; i++)
        rknn_run(ctx, NULL);

    int cap = seconds > 0 ? 100000 : runs;
    double *lat = malloc(sizeof(double) * cap);
    int n = 0;
    double start = now_ms();
    while (n < cap) {
        double a = now_ms();
        ret = rknn_run(ctx, NULL);
        lat[n] = now_ms() - a;
        if (ret < 0) {
            fprintf(stderr, "rknn_run failed: %d\n", ret);
            return 1;
        }
        n++;
        if (seconds > 0 && now_ms() - start >= seconds * 1e3)
            break;
    }
    double total = now_ms() - start;

    rknn_mem_size mem;
    memset(&mem, 0, sizeof(mem));
    rknn_query(ctx, RKNN_QUERY_MEM_SIZE, &mem, sizeof(mem));

    double sum = 0;
    for (int i = 0; i < n; i++)
        sum += lat[i];
    qsort(lat, n, sizeof(double), cmp_double);
    printf("NPU %s: input %dx%dx%d, init %.0f ms, %d runs: avg %.2f ms, min %.2f, p50 %.2f, p95 %.2f, max %.2f "
           "=> %.1f inferences/s; mem: weights %.2f MB, internal %.2f MB, "
           "total DMA %.2f MB\n",
           model, in_attr.dims[1], in_attr.dims[2], in_attr.dims[3], init_ms, n, sum / n, lat[0], lat[n / 2],
           lat[(int)(n * 0.95)], lat[n - 1], n / (total / 1e3),
           mem.total_weight_size / 1048576.0, mem.total_internal_size / 1048576.0,
           mem.total_dma_allocated_size / 1048576.0);

    for (uint32_t i = 0; i < io.n_output; i++)
        rknn_destroy_mem(ctx, out_mem[i]);
    rknn_destroy_mem(ctx, in_mem);
    rknn_destroy(ctx);
    return 0;
}
