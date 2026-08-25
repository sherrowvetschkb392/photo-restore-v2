# Photo Restore V2

面向 RK3588 的离线老照片修复工作站。

当前阶段：RKNN 模型、板端 NPU 推理、批量验证和单图 CLI 已验证；下一阶段是
大图生产化和本地用户界面。

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
