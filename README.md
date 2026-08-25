# Photo Restore V2

面向 RK3588 的离线老照片修复工作站。

当前阶段：RKNN 模型、板端 NPU 推理、批量验证、单图 CLI、FastAPI/Web UI、
systemd 服务和受 Cloudflare Access 保护的公网入口均已验证。下一阶段是大图
生产化、轻量预览与长期存储治理。

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

原始需求、当前完成度和后续缺口见 `docs/requirements-status.md`；图片输入输出
约定见该文档的 “Current image contract” 小节。

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
