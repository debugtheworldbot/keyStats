# KeyStats iCloud 同步功能实现

此项目实现了 KeyStats macOS 应用的 iCloud 同步功能，解决了 issue #39 中提出的需求。

## 功能特点

- **跨设备同步**: 统计数据可在所有用户的设备间同步
- **自动同步**: 每5分钟自动同步一次数据
- **设置控制**: 用户可在设置中启用/禁用同步功能
- **数据恢复**: 首次启用同步时可选择从 iCloud 恢复历史数据
- **隐私保护**: 所有数据仅存储在用户的私有 iCloud 容器中

## 技术实现

- 使用苹果的 CloudKit 和 NSUbiquitousKeyValueStore 进行数据同步
- 遵循苹果的沙盒和隐私指南
- 优雅降级：当 iCloud 不可用时，应用继续正常工作

## 文件变更

- `iCloudManager.swift`: 核心同步管理器
- `CloudSyncProtocol.swift`: 云同步协议定义
- `StatsManager.swift`: 集成同步逻辑
- `SettingsViewController.swift`: 添加设置 UI
- `KeyStats.entitlements`: 添加 iCloud 权限
- 本地化字符串文件: 添加新功能的中英文翻译

## 如何提交

参见 `FINAL_STEPS.md` 文件了解如何完成 GitHub 提交流程。