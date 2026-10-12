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
| RetinaFace | 640×640 | 25 / 26 ms | 40 | 6.4 MB |
| MobileFaceNet | 160×160 | 4.5 / 4.7 ms | 221 | 4.2 MB |

- The CPU stays nearly free during inference (~1–2 %).
- Times exclude pre-processing (resize/RGA) and post-processing (decode, NMS).

## Encoder (MPP `mpi_enc_test`, 300 frames)

| Resolution | H.264 | H.265 | Media memory |
|---|---|---|---|
| **2304×1296** (SC3336) | **39 fps** | **37 fps** | 19.6 MB |
| 1920×1080 | 56 fps | 53 fps | 13.3 MB |
| 1280×720 | 103 fps | 103 fps | 6.2 MB |

The rockit test tool (`rk_mpi_venc_test`) runs at a fixed ~20 fps whatever the codec or content. That limit is the tool, not the encoder.

## Both at once (YOLOv5 640 + 1296p encode, 20 s)

- **YOLOv5: 94 ms (10.7/s, −13 %)**
- **Encoder: ~31 fps (−19 %)**. It still keeps up with a 30 fps camera, with little margin.
- **Media heap peak 36.6 of 66 MB**; Linux `MemAvailable` −3 MB; up to 69 °C.

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
