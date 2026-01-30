# iCloud Sync Feature Implementation

## Summary
This PR implements iCloud synchronization functionality for KeyStats, allowing users to sync their keyboard and mouse statistics across multiple Mac devices using the same Apple ID.

## Changes Made

### New Features
- Added iCloud sync toggle in the Settings panel
- Implemented automatic syncing of statistics every 5 minutes when enabled
- Added option to restore data from iCloud when first enabling sync
- Created dedicated iCloudManager to handle all cloud-related operations

### Technical Implementation
- Added iCloud entitlements to the app
- Created CloudSyncProtocol for potential future cloud providers
- Integrated iCloud sync with the existing StatsManager
- Added both English and Chinese localization for new features

### Files Modified
- `KeyStats/StatsManager.swift`: Integrated iCloud sync functionality
- `KeyStats/SettingsViewController.swift`: Added sync toggle and related UI
- `KeyStats/KeyStats.entitlements`: Added iCloud-related entitlements
- `KeyStats/en.lproj/Localizable.strings`: Added English localization
- `KeyStats/zh-Hans.lproj/Localizable.strings`: Added Chinese localization
- `KeyStats/iCloudManager.swift`: New file implementing iCloud sync logic
- `KeyStats/CloudSyncProtocol.swift`: New protocol for cloud sync interface

## How It Works
1. When iCloud sync is enabled in settings, the app automatically syncs data to iCloud every 5 minutes
2. When the app becomes active, it checks for updates from other devices
3. Users can choose to restore data from iCloud when first enabling the feature
4. Data is stored in the app's private iCloud container and includes both current day stats and historical data

## Requirements
- User must have iCloud enabled on their Mac
- User must sign in with the same Apple ID on all devices
- App must have appropriate permissions granted by the user

## Testing
The implementation follows Apple's guidelines for iCloud integration using UIDocumentPicker and NSUbiquitousKeyValueStore for synchronization. The feature has been designed to be robust against network failures and gracefully degrade when iCloud is unavailable.