---
created: 2026-10-12
tags:
  - type/project-doc
  - area/electronics
  - area/ai-ml
  - project/luckfox-alpr
---

# Board benchmarks: NPU, H.264/H.265, RAM (Luckfox Pico Max)

Phase 2's "baseline numbers", measured **without a camera**. Scripts, the full table and how to run them: `bench/README.md` in [Zektopic/luckfox-esp-hosted](https://github.com/Zektopic/luckfox-esp-hosted) (`Documents/GitHub/ESP32/esp-hosted/bench/`). Move them to `luckfox-alpr` later.

**Setup:** RV1106G3, 256 MB; CPU 1104 MHz, NPU 420 MHz, VEPU 396 MHz; `librknnmrt` 1.6.0, RKNPU 0.9.2. Bare board at 54–69 °C. The 3-h Wi-Fi soak was running alongside.

## NPU (my `rknn_bench`, zero-copy API, 200 runs)

| Model (prebuilt, `luckfox_pico_rknn_example`) | Input | Avg / p95 | Per second | NPU memory |
|---|---|---|---|---|
| **YOLOv5s** | 640×640 | **81 / 82 ms** | **12.3** | 13.7 MB (7.0 weights + 6.5 internal) |
| RetinaFace | 640×640 | 25 / 25 ms | 40 | 6.4 MB |
| MobileFaceNet | 160×160 | 4.4 / 4.4 ms | 227 | 4.2 MB |

- The CPU stays nearly free during inference (2–3 %). Repeat runs agree within 1 %, whatever the background CPU load.
- Times exclude pre-processing (resize/RGA) and post-processing (decode, NMS).

## Encoder (MPP `mpi_enc_test`, 300 frames)

| Resolution | H.264 | H.265 | Media memory |
|---|---|---|---|
| **2304×1296** (SC3336) | **39 fps** | **37 fps** | 19.6 MB |
| 1920×1080 | 55 fps | 53 fps | 13.3 MB |
| 1280×720 | 118 fps | 112 fps | 6.2 MB |

- Measured with exact timing during a soak download segment. Repeats gave 38.2–38.4 fps including start-up.
- The test generates its frames on the CPU (~30 %). During a soak *upload* (Wi-Fi driver at ~28 % CPU) it drops to ~35 fps; a camera would feed frames by DMA instead.
- The rockit test tool (`rk_mpi_venc_test`) runs at a fixed ~20 fps whatever the codec or content. That limit is the tool, not the encoder.

## Both at once (YOLOv5 640 + 1296p H.264, 20 s, 3 runs back to back with solo runs)

- **YOLOv5: 96 ms (10.4/s), +18 %**: the NPU loses to shared-DDR contention.
- **Encoder: 37.5 fps, −2 %**: it hardly notices. That leaves ~25 % margin over a 30 fps camera, but the real pipeline adds ISP traffic, so **confirm with the camera attached**.
- **Media heap peak 36.6 of 66 MB**; Linux `MemAvailable` −1.5 MB; up to 70 °C. Runs were 20 s on a bare board, so sustained load is untested.
- A first combined run during a soak upload gave ~31 fps. That drop was CPU contention with the Wi-Fi upload, not the NPU.

## RAM: where the 256 MB goes

- ~7.5 MB kernel.
- **66 MB media DMA heap** (`rk_dma_heap_cma=66M`, reserved at boot): ISP/VI, encoder, NPU and RGA buffers. Monitor it via `/proc/rk_dma_heap/alloc_bitmap`.
- **~180 MB Linux** (`MemTotal`). Idle: ~25–45 MB used, ~135–150 MB available.
- So for ALPR the limit is the **media heap, not Linux RAM**. Detector + recording take ~37 MB, leaving ~29 MB for the camera buffers (~4.5 MB per 1296p NV12 frame).
- Storage is tiny: `/userdata` has 2 MB free and `/oem` 4 MB; `/tmp` is RAM.

## Other findings

- **Wi-Fi upload via ESP-Hosted costs CPU:** ~2.7 Mbit/s up uses ~28 % (`esp_TX`) + ~15 % softirq/kworker. Send events and crops, not video.
- **Don't `cat /proc/rknpu/volt`.** It oopses the kernel (NULL regulator in the stock driver).
- `mpi_enc_test -i <file>` is broken on this build. Without `-i` it generates frames.

## Next

- Convert the plate detector at 640, 480 and 320 input (rknn-toolkit2 on the build PC) and time each one.
- With the SC3336 attached: repeat with VI → VENC bind and real ISP buffers, for the real media-heap and RAM figures.

## Related Notes

- [[04-Step-by-Step-Plan]] — Phase 2 measurements
- [[09-Testing-and-Validation]]
- [[11-ESP-Hosted-on-ESP32-C6]] — the Wi-Fi link whose CPU cost is measured here
