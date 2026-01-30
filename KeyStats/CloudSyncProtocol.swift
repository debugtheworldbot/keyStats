import Foundation

protocol CloudSyncProtocol {
    func syncData()
    func restoreFromCloud(completion: @escaping (Bool) -> Void)
    func hasCloudBackup() -> Bool
    func manualSync()
}