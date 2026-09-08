此目录包含 Skype SILK SDK 1.0.9，用于解码 OneBot/Milky 承载的 SILK V3 语音。

- 上游：https://github.com/kn007/silk-v3-decoder
- 固定提交：`507be6bca8ce1fb977a061481f1d79e8c610e309`
- 导入范围：`silk/src` 的可移植 C 源码/头文件与 `silk/interface`，保留版权声明。未引入仅适用于 ARMv7 的 `.S` 汇编实现。
- `ReiSilk.c` 与 `include/ReiSilk.h` 是本项目新增的最小解码接口，不使用上游 CLI。
- SDK 授权以每个源码文件头部及本目录 `LICENSE` 为准。该授权明确不授予专利权；上游仓库根目录的 MIT 声明不替代 SDK 声明。

Swift 层解析标准 `#!SILK_V3` 与腾讯 `0x02 + #!SILK_V3` 包装，检查包长度和帧数，再调用 SDK；所有输出均为 24 kHz 单声道 PCM。
