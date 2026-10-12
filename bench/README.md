# Luckfox Pico Max benchmarks: NPU, H.264/H.265 encoder, RAM (2026-10-12)

Measured on the board itself: RV1106G3, 256 MB, stock Luckfox SDK image plus the ESP-Hosted additions; kernel 5.10.160; `librknnmrt` 1.6.0; RKNPU driver 0.9.2; MPP `16e796a4`.

**Conditions:**
- Clocks: CPU (`armclk`) 1104 MHz, NPU 420 MHz, VEPU 396 MHz. SoC temperature 54–69 °C, bare board, no heatsink.
- **No camera attached.** The encoder is fed generated or file frames, and the NPU a fixed pseudo-random image.
- **The 3-h Wi-Fi soak was running at the same time** (iperf3 over `wlan0`). See the "CPU" section for what it costs.

## Results

### NPU (`npu/rknn_bench.c`: 200 runs after 5–10 warm-ups, zero-copy API)

| Model (prebuilt RV1106 `.rknn` from `luckfox_pico_rknn_example`) | Input | Latency avg / p95 / max | Inferences/s | NPU DMA memory (runtime report) | CPU of the process |
|---|---|---|---|---|---|
| **YOLOv5s** (COCO) | 640×640×3 | **81.1 / 81.8 / 92 ms** | **12.3** | 13.7 MB (weights 7.0 + internal 6.5); heap peak 16.9 MB | 2 % |
| RetinaFace | 640×640×3 | 24.8 / 25.1 / 30 ms | 40.4 | 6.4 MB; heap peak 7.9 MB | 3 % |
| MobileFaceNet | 160×160×3 | 4.41 / 4.43 / 8.7 ms | 227 | 4.2 MB; heap peak 4.3 MB | 3 % |

Repeat runs agreed within 1 % (YOLOv5: 81.1–81.6 ms), whether the soak was uploading or downloading. NPU timing doesn't depend on CPU load.

- `rknn_init` takes 40–130 ms. `rknn_run` blocks in the kernel, so the CPU stays free while the NPU works.
- Pre-processing (resize/convert, e.g. on the RGA) and post-processing (box decoding, NMS) aren't included.
- This runtime doesn't support `RKNN_QUERY_PERF_RUN`.

### Hardware encoder (`venc-bench.sh`: MPP `mpi_enc_test`, 300 frames, generated test frames, output discarded)

| Resolution | H.264 fps | H.265 fps | Media DMA memory | CPU of the process* |
|---|---|---|---|---|
| **2304×1296** (SC3336 native) | **39.3** (3 repeats incl. start-up: 38.2–38.4) | **37.2** | 19.6 MB | 30–32 % |
| 1920×1080 | 55.0 | 53.4 | 13.3 MB | 30–32 % |
| 1280×720 | 118 | 112 | 6.2 MB | 32–33 % |

Measured during a soak *download* segment (~4 % background CPU), with exact timing (fps excludes the ~0.1–0.2 s start-up).

\* Most of this is `mpi_enc_test` generating the frame on the CPU. With a camera, the frames arrive by DMA (VI → VENC bind).

- **Background CPU load slows this test.** During a soak *upload* segment (ESP-Hosted `esp_TX` at ~28 % CPU), the same 1296p H.264 run gave ~35 fps instead of 38–39. The frame generation competes for the single core.
- An earlier pass used a sampler with coarse timing, and its 720p figures (103 fps) were quantised. The numbers above replace it.

- The rockit/RK_MPI path (`rk_mpi_venc_test`, what the camera apps use) at 2304×1296 runs at a fixed ~50 ms/frame (~20 fps) **whatever the codec or content**: the test tool sets the pace. Media memory 17.9 MB.
- `mpi_enc_test -i <file>` fails (`mpp run failed ret -1`) on this build; without `-i` it generates frames.

### Combined: YOLOv5 640 on the NPU + 2304×1296 H.264 at once (`combined-bench.sh`, 20 s, 3 runs)

Run back to back with the solo runs inside one soak download segment (`logs/bench-rerun-download-segment-2026-10-12.txt`):

| | Solo | Combined (3 runs) | Change |
|---|---|---|---|
| YOLOv5 latency avg / p95 | 81.1 / 81.8 ms (12.3/s) | **95.7–95.8 / 97.8–98.1 ms (10.4/s)** | **+18 %** |
| Encoder fps (incl. start-up) | 38.2–38.4 | **37.3–37.7** | −2 % |
| Media DMA heap peak | 16.9 / 19.6 MB | **36.6 MB of 66 MB** | |
| MemAvailable drop | 0.5 MB | 1.2–1.7 MB | |
| SoC temperature | | 60 → 70 °C | |

- The NPU loses ~18 % to shared-DDR contention; the encoder hardly notices.
- An earlier combined run during a soak *upload* segment gave 94 ms and ~31 fps. That fps drop came from CPU contention with the Wi-Fi upload, not from the NPU.
- At 1296p, ~37 fps alongside YOLOv5 leaves ~25 % margin over a 30 fps camera. But the real pipeline adds ISP/VI traffic on the same DDR, and the test frames came from the CPU. **Confirm with the camera attached.**
- Runs were 20 s long on a bare board that was still warming (up to 70 °C). Sustained load, especially in a car, is still untested.

## RAM

| | |
|---|---|
| Physical | 256 MB |
| Kernel code and data | ~7.5 MB |
| **Media DMA heap** (`rk_dma_heap_cma=66M`, reserved at boot at 0x0be00000–0x0fffffff) | **66 MB**, for ISP/VI, encoder, NPU and RGA buffers. It's *not* part of Linux's `MemTotal`, which is why encoder/NPU buffers barely move `MemAvailable`. Watch `/proc/rk_dma_heap/alloc_bitmap` (`Used:`) |
| Linux (`MemTotal`) | ~180 MB. Idle with Wi-Fi and the soak running: ~25–45 MB used, `MemAvailable` ~135–150 MB |
| Storage | `/userdata` has 2 MB free and `/oem` 4 MB; `/tmp` is RAM. Models and binaries for testing go in `/tmp` |

ALPR budget (YOLOv5-class detector plus 1296p recording) uses ~37 MB of the 66 MB heap. The camera path (VI/ISP raw and NV12 buffers, about 4.5 MB per 1296p NV12 frame) has to fit in the remaining ~29 MB, so the **media heap, not Linux RAM, is the limit to watch**. All figures are lower bounds until a camera is attached.

## CPU (single Cortex-A7)

- NPU inference: 2–3 % of the CPU (`rknn_run` waits in the kernel). Encoding: expected to be low once the frames come from the camera by DMA; here ~30 % is the test generating its frames.
- **Wi-Fi upload through ESP-Hosted is expensive:** while the soak sends ~2.7 Mbit/s, the driver's `esp_TX` thread uses ~28 % CPU, plus ~10 % softirq and ~4 % kworker. Downloads cost ~4 %. Avoid streaming video over this link; send events and crops.
- Measuring CPU: an early version of `memwatch.sh` forked `awk`/`sed` for every sample and cost ~55 % CPU on its own. The current one reads with shell builtins only.

## Gotchas

- **Don't read `/proc/rknpu/volt`.** It triggers a kernel oops (NULL regulator in `rknpu_volt_show`). The kernel survived, but leave that file alone.
- `/proc/rknpu/load` lags by ~3 s (`delayms`), so an encoder run right after an NPU run still shows the old NPU load.

## How to run

```sh
# build the NPU benchmark (Linux build PC, SDK toolchain; header + models from LuckfoxTECH/luckfox_pico_rknn_example)
git clone --depth 1 https://github.com/LuckfoxTECH/luckfox_pico_rknn_example.git
TC=~/luckfox/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf/bin/arm-rockchip830-linux-uclibcgnueabihf-gcc
$TC -O2 -Wall -o rknn_bench bench/npu/rknn_bench.c -Iluckfox_pico_rknn_example/include/rknn \
    -Lluckfox_pico_rknn_example/lib/uclibc -lrknnmrt
# copy everything to the board's /tmp (RAM), then:
ssh luckfox 'sh /tmp/venc-bench.sh 300'                                  # encoder matrix
ssh luckfox 'cd /tmp; LD_LIBRARY_PATH=/oem/usr/lib ./memwatch.sh yolov5 ./rknn_bench /tmp/yolov5.rknn 200 10'
ssh luckfox 'sh /tmp/combined-bench.sh 20 7 2304x1296'                  # NPU + encoder
```

Raw outputs: `logs/bench-*-2026-10-12.txt`. These scripts belong with the ALPR app and can move to the `luckfox-alpr` repo later.

**Next:** convert the planned plate detector at 640, 480 and 320 input with rknn-toolkit2 on the build PC to choose the input size. Then repeat with the SC3336 attached (VI → VENC bind, real ISP buffers) for the real RAM and media-heap figures.
