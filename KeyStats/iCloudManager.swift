import Foundation
import CloudKit

/// iCloud 同步管理器
class iCloudManager: NSObject, CloudSyncProtocol {
    static let shared = iCloudManager()
    
    private let container: CKContainer
    private let database: CKDatabase
    private let ubiquityURL: URL?
    
    // iCloud 状态观察
    private var iCloudAvailable = false
    private let ubiquityKVStore: NSUbiquitousKeyValueStore
    
    // 回调队列
    private let callbackQueue = DispatchQueue(label: "iCloudCallbackQueue", qos: .utility)
    
    override init() {
        // 使用默认容器
        self.container = CKContainer.default()
        self.database = CKContainer.default().privateCloudDatabase
        
        // 获取 ubiquity 容器 URL
        self.ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        
        // 初始化键值存储
        self.ubiquityKVStore = NSUbiquitousKeyValueStore.default
        
        super.init()
        
        // 监听 ubiquity KV 存储变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquityKVStoreChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquityKVStore
        )
        
        // 检查 iCloud 可用性
        checkiCloudAvailability()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// 检查 iCloud 可用性
    private func checkiCloudAvailability() {
        container.accountStatus { [weak self] (status, error) in
            self?.callbackQueue.async {
                let available = (status == .available)
                self?.iCloudAvailable = available
                
                if available {
                    print("☁️ iCloud 已启用")
                    // 立即同步数据
                    self?.syncData()
                } else {
                    print("☁️ iCloud 不可用: \(error?.localizedDescription ?? "Account status: \(status.rawValue)")")
                }
            }
        }
    }
    
    /// 监听 ubiquity KV 存储变化
    @objc private func ubiquityKVStoreChanged(notification: Notification) {
        guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }
        
        for key in changedKeys {
            if key == "statsSyncTrigger" {
                // 触发同步
                syncData()
            }
        }
    }
    
    /// 同步数据到 iCloud
    func syncData() {
        guard iCloudAvailable, let ubiquityURL = ubiquityURL else {
            print("☁️ iCloud 不可用，跳过同步")
            return
        }
        
        // 使用 ubiquity 容器中的 Documents 目录
        let iCloudDocumentsURL = ubiquityURL.appendingPathComponent("Documents")
        
        // 创建目录
        do {
            try FileManager.default.createDirectory(at: iCloudDocumentsURL, withIntermediateDirectories: true)
        } catch {
            print("☁️ 创建 iCloud 目录失败: \(error)")
            return
        }
        
        // 从本地读取统计数据
        let userDefaults = UserDefaults.standard
        if let currentStatsData = userDefaults.data(forKey: "dailyStats"),
           let historyData = userDefaults.data(forKey: "dailyStatsHistory") {
            
            // 写入 iCloud 文档目录
            let currentStatsURL = iCloudDocumentsURL.appendingPathComponent("dailyStats.json")
            let historyStatsURL = iCloudDocumentsURL.appendingPathComponent("dailyStatsHistory.json")
            
            do {
                try currentStatsData.write(to: currentStatsURL)
                try historyData.write(to: historyStatsURL)
                
                print("☁️ 统计数据已同步到 iCloud")
                
                // 更新键值存储以通知其他设备
                ubiquityKVStore.set(Date().timeIntervalSince1970, forKey: "statsSyncTrigger")
                ubiquityKVStore.synchronize()
                
            } catch {
                print("☁️ 写入 iCloud 失败: \(error)")
            }
        }
    }
    
    /// 从 iCloud 恢复数据
    func restoreFromiCloud(completion: @escaping (Bool) -> Void) {
        guard iCloudAvailable, let ubiquityURL = ubiquityURL else {
            completion(false)
            return
        }
        
        let iCloudDocumentsURL = ubiquityURL.appendingPathComponent("Documents")
        let currentStatsURL = iCloudDocumentsURL.appendingPathComponent("dailyStats.json")
        let historyStatsURL = iCloudDocumentsURL.appendingPathComponent("dailyStatsHistory.json")
        
        var restored = false
        
        // 读取并恢复统计数据
        if let currentStatsData = try? Data(contentsOf: currentStatsURL) {
            UserDefaults.standard.set(currentStatsData, forKey: "dailyStats")
            restored = true
        }
        
        if let historyData = try? Data(contentsOf: historyStatsURL) {
            UserDefaults.standard.set(historyData, forKey: "dailyStatsHistory")
            restored = true
        }
        
        if restored {
            print("☁️ 从 iCloud 恢复统计数据成功")
        } else {
            print("☁️ iCloud 中未找到统计数据")
        }
        
        completion(restored)
    }
    
    /// 检查是否有待恢复的 iCloud 数据
    func hasiCloudBackup() -> Bool {
        guard iCloudAvailable, let ubiquityURL = ubiquityURL else {
            return false
        }
        
        let iCloudDocumentsURL = ubiquityURL.appendingPathComponent("Documents")
        let currentStatsURL = iCloudDocumentsURL.appendingPathComponent("dailyStats.json")
        let historyStatsURL = iCloudDocumentsURL.appendingPathComponent("dailyStatsHistory.json")
        
        return (try? Data(contentsOf: currentStatsURL)) != nil || 
               (try? Data(contentsOf: historyStatsURL)) != nil
    }
    
    /// 手动触发 iCloud 同步
    func manualSync() {
        syncData()
    }
}