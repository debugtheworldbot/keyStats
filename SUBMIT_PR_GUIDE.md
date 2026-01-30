# 如何提交 iCloud 同步功能 PR

## 步骤 1: Fork 仓库
1. 访问 https://github.com/debugtheworldbot/keyStats
2. 点击右上角的 "Fork" 按钮

## 步骤 2: 克隆你的 Fork
```bash
git clone https://github.com/[你的用户名]/keyStats.git
cd keyStats
```

## 步骤 3: 应用补丁
将附件中的 `icloud-sync-feature.patch` 文件复制到你的本地仓库目录，然后运行：
```bash
git apply icloud-sync-feature.patch
```

## 步骤 4: 创建新分支
```bash
git checkout -b feature/icloud-sync
```

## 步骤 5: 提交更改
```bash
git add .
git commit -m "feat: Add iCloud sync functionality

- Implement iCloud sync for cross-device data synchronization
- Add iCloud sync toggle in settings
- Create iCloudManager to handle sync operations
- Add necessary entitlements for iCloud access
- Add localization strings for iCloud features"
```

## 步骤 6: 推送到 GitHub
```bash
git push origin feature/icloud-sync
```

## 步骤 7: 创建 Pull Request
1. 访问你的仓库页面
2. 点击 "Pull requests" 标签
3. 点击 "New pull request" 
4. 选择 `feature/icloud-sync` 分支与主仓库的 `main` 分支进行比较
5. 创建 PR

## 功能说明
这个补丁实现了 issue #39 中请求的 iCloud 同步功能：

- 添加了 iCloud 同步开关在设置面板中
- 实现了自动同步统计数据到 iCloud
- 添加了从 iCloud 恢复数据的选项
- 包含中英文本地化
- 添加了必要的 entitlements 权限
- 遵循苹果的 iCloud 开发指南

## 测试要点
- 确保有 iCloud 账户并已登录
- 测试同步开关是否正常工作
- 测试数据是否正确上传到 iCloud
- 测试从 iCloud 恢复数据功能
- 验证设置界面的 UI 元素