# Photo Restore V2

面向 RK3588 的离线老照片修复工作站。

当前阶段：设备审计与 RKNN 推理基线验证。

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

三端目录结构和保留策略见 `docs/filesystem-layout.md`。只读盘点：

```powershell
.\scripts\inventory-storage.ps1
```
