# Photo Restore V2

面向 RK3588 的离线老照片修复工作站。

当前阶段：设备审计与 RKNN 推理基线验证。

## 目录

- `scripts/`：部署和设备审计脚本
- `apps/`：后续 API、Worker 与 Web 应用
- `tests/`：自动化测试
- `docs/`：设计与部署文档
- `benchmarks/`：本地基准结果（结果文件不进入 Git）

旧板端项目不在本项目范围内。本项目板端根目录固定为：

```text
/userdata/photo-restore-v2
```

