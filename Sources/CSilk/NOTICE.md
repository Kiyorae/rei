# SILK SDK Provenance

This directory contains Skype SILK SDK 1.0.9 to decode SILK V3 voice messages carried by OneBot
and Milky.

- Upstream: <https://github.com/kn007/silk-v3-decoder>
- Pinned commit: `507be6bca8ce1fb977a061481f1d79e8c610e309`
- Imported scope: portable C sources and headers from `silk/src` and `silk/interface`, with
  copyright notices preserved. ARMv7-only `.S` assembly implementations are excluded.
- `ReiSilk.c` and `include/ReiSilk.h` provide Rei's minimal decoding interface; the upstream CLI
  is not used.
- SDK licensing is defined by the source file headers and [LICENSE](LICENSE) in this directory.
  That license explicitly grants no patent rights; the upstream repository's root MIT notice does
  not replace the SDK notices.

The Swift layer parses standard `#!SILK_V3` and Tencent `0x02 + #!SILK_V3` wrappers and validates
packet lengths and frame counts before calling the SDK. All output is 24 kHz mono PCM.
