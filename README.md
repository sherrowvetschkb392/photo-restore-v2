# Photo Restore V2

面向 RK3588 的离线老照片修复工作站。

当前阶段：RKNN 模型、板端 NPU 推理、批量验证、单图 CLI、FastAPI/Web UI、
systemd 服务、Cloudflare Access 公网入口、长期存储治理和生产健康监控均已验证。
下一阶段是生产安全与可恢复性补强，以及隔离的视频智能插帧技术预检。

已确定首版推理参数：RealESRGAN x4plus FP16、固定 96×96 输入 tile、
每边初始重叠 8 输入像素。最终 overlap 由真实照片接缝测试确认。

## 目录

- `scripts/`：部署和设备审计脚本
- `apps/`：后续 API、Worker 与 Web 应用
- `tests/`：自动化测试
- `docs/`：设计与部署文档
- `benchmarks/`：本地基准结果（结果文件不进入 Git）
- `config/`：不含密钥的配置模板

旧板端项目不在本项目范围内。本项目板端根目录固定为：

```text
/userdata/photo-restore-v2
```

## 板端环境基线

- Debian 11 / aarch64 / Python 3.9
- RKNN NPU driver 0.9.2
- RKNN Runtime 2.3.2
- RKNNLite2 2.3.2（仅安装到项目虚拟环境）

运行只读 Runtime 检查：

```powershell
.\scripts\deploy-runtime-check.ps1
```

完整构建并在 RK3588 验证一个模型：

```powershell
.\scripts\build-and-validate-model.ps1 -TileSize 96 -Runs 5
```

选择最终 tile 尺寸：

```powershell
.\scripts\benchmark-tile-matrix.ps1
```

详细流程见 `docs/development-workflow.md`。

完整产品需求、图片修复与视频插帧范围、验收标准和分阶段开发顺序见
`docs/product-requirements-roadmap.md`。简明完成度见 `docs/requirements-status.md`；
图片输入输出约定见该文档的 “Current image contract” 小节。

三端目录结构和保留策略见 `docs/filesystem-layout.md`。只读盘点：

```powershell
.\scripts\inventory-storage.ps1
```

运行小型图片端到端原型验收（核心测试、依赖检查、板端推理和结果回传）：

```powershell
.\scripts\deploy-image-prototype.ps1
```

样图验收通过后，处理一张真实照片（首版最多 2,000,000 输入像素）：

```powershell
.\scripts\restore-photo.ps1 -InputImage "C:\path\to\photo.jpg"
```

默认输出到 `benchmarks\restored\`，同时生成 JSON 运行报告。输入和输出均被
`.gitignore` 排除，不会提交到 Git。结果成功下载后，板端该任务的输入、输出和
报告会自动清理；调试时可加 `-KeepRemoteArtifacts` 保留。

批量验证集的原图固定放在 `data\validation\<名称>\raw\`，来源和许可证清单
放在 `datasets\manifests\`。批量运行示例：

```powershell
.\scripts\restore-validation-set.ps1 -DatasetName "public-domain-history"
```

若要丢弃该数据集上次生成的结果并从第一张重新运行：

```powershell
.\scripts\restore-validation-set.ps1 -DatasetName "div2k-x4-sample" -RestartDataset
```

验证磁盘合成器的第一档大图能力（默认 1280×720，约 92 万像素）：

```powershell
.\scripts\benchmark-large-image.ps1
```

该命令通过已部署 API 运行真实 NPU 任务，验证磁盘合成、完整 4×输出和轻量
预览，并将忽略 Git 的报告写入 `benchmarks\large-image\`。测试任务完成后会
自动从板端删除。

已验证的当前上限结果：

- 1280×720（921,600 像素）：总耗时 74.681 秒，峰值 RSS 470,232 KiB；
- 1920×1000（1,920,000 像素）：总耗时 158.146 秒，峰值 RSS 622,344 KiB；
- 2000×1500（3,000,000 像素）：在第 211/475 个 tile 后触发 RKNN
  Runtime 2.3.2 / NPU 驱动卡死，需要重启板子复位。

因此公网输入上限固定为 2,000,000 像素，不应提高到 3MP。直接 3MP
脚本仅保留为隔离驱动诊断工具，默认禁止启动；只有明确接受可能需要重启板子时
才可运行：

```powershell
.\scripts\benchmark-large-image-direct.ps1 -AcknowledgeDriverResetRisk
```

清理该诊断工具的精确板端目录不会重新生成图片或启动推理：

```powershell
.\scripts\benchmark-large-image-direct.ps1 -Cleanup
```

公网任务存储由 API 自动维护：已完成或失败的任务默认保留 7 天；任务目录达到
4 GiB 或板端可用空间低于 2 GiB 时，从最旧的已结束任务开始回收。排队中和
运行中的任务不会被自动删除。清理巡检默认每 15 分钟运行一次，所有参数均由
`config\photo-restore-api.service` 固定并随部署同步。

只读检查生产服务、Cloudflare Tunnel、任务队列、NPU、温度与磁盘：

```powershell
.\scripts\check-production-health.ps1
```

该命令不会删除任务、终止进程或重启板子。结果同时写入忽略 Git 的
`benchmarks\production-health\latest.json`；若发现运行任务超过 10 分钟且 NPU
持续高负载，会提示疑似驱动卡死并要求人工检查。

只读盘点 RK3588 的视频研发基础（FFmpeg/ffprobe、MPP/RGA、硬件编解码证据、
GStreamer、设备节点、内存、磁盘、温度和现有生产服务）：

```powershell
.\scripts\video-preflight.ps1
```

该命令不会安装软件、修改 systemd、启动视频推理或触碰现有图片任务。原始证据和
结构化报告分别写入忽略 Git 的 `benchmarks\video-preflight\latest-raw.txt` 与
`latest.json`。离线验证脚本自身的解析和边界检查：

```powershell
.\scripts\video-preflight.ps1 -ValidateOnly
```

真实预检确认板端已有 MPP/RGA 和 GStreamer Rockchip 硬件编解码插件，但缺少
FFmpeg/ffprobe。先只模拟 Debian FFmpeg 安装计划：

```powershell
.\scripts\install-video-tools.ps1
```

确认没有删除或替换 Rockchip 包后，才显式安装：

```powershell
.\scripts\install-video-tools.ps1 -Install
```

详细证据、工具分工和下一项硬件编解码冒烟测试见
`docs/video-development.md`。

FFmpeg/ffprobe 安装和复验通过后，运行隔离的 640×360 MPP 硬件编解码测试：

```powershell
.\scripts\test-video-codec.ps1
```

该命令必须实际使用 `mpph264enc` 和 `mppvideodec`，生成带 AAC 音频的 10 秒
MP4，并用 ffprobe 验证尺寸、帧率、帧数、时长和音频。它不会运行 RKNN 模型，
也不会停止或重启图片 API 与 Cloudflare Tunnel。

生成模型无关的 256×256 相邻帧/真实中间帧夹具，并验证统一插帧输出合同：

```powershell
.\scripts\prepare-interpolation-fixtures.ps1
```

夹具覆盖线性运动、遮挡/显露、细线纹理和场景切换；候选模型输出必须优于复制邻帧
与简单平均基线，场景切换必须跳过模型。生成数据和评估报告均被 Git 忽略。

生成视频空间增强（画质/分辨率）夹具：

```powershell
.\scripts\prepare-video-enhancement-fixtures.ps1
```

该合同要求短时序输入输出 2× 或 4× 高分辨率帧，并同时检查空间误差与时间一致性；
场景切换必须重置时序状态。它用于筛选 BasicVSR++、RealBasicVSR、RVRT 等候选，
不会把图片 Real-ESRGAN 逐帧直接冒充视频修复。

模型下载前的候选评审表见 `docs/video-model-candidate-review.md` 和
`datasets/manifests/video-model-candidates.json`；当前只做来源、许可证和算子风险
登记，不会自动下载权重或修改板端服务。

校验候选清单（只读）：

```powershell
python tools/validate_video_model_manifest.py datasets/manifests/video-model-candidates.json
```

联网可用时，只读取候选公开仓库的元数据、许可证接口和 README（不下载权重、不上传板子）：

```powershell
.\scripts\fetch-video-model-metadata.ps1 -Candidate RealBasicVSR
```

结果隔离在 `data\video-development\model-candidates\`，需要人工确认具体提交、许可证
和权重来源后，才允许进入 ONNX/RKNN 评估。重复运行会复用已有记录；只有需要刷新
公开元数据时才加 `-Force`。

读取 RealBasicVSR 的配置目录和模型说明（仍不下载权重）：

```powershell
.\scripts\fetch-video-model-details.ps1 -Candidate RealBasicVSR
```

BasicVSR++ 4×官方权重下载计划（不下载）：

```powershell
.\scripts\download-video-model-artifacts.ps1 -Candidate "BasicVSR++"
```

确认计划后再实际下载到项目隔离缓存（仍不上传板子）：

```powershell
.\scripts\download-video-model-artifacts.ps1 -Candidate "BasicVSR++" -DownloadWeights
```

下载后验证文件完整性：

```powershell
python tools/verify_video_model_artifacts.py `
  data/video-development/model-candidates/BasicVSR++/weights-record.json
```

导出 ONNX 后先做算子/动态形状审计：

```powershell
python tools/audit_onnx_graph.py path/to/video-model.onnx `
  --report benchmarks/video-model-candidates/onnx-audit.json
```
