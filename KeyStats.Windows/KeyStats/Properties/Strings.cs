using System.Resources;

namespace KeyStats.Properties;

// Hand-written accessor class. Each migration task adds new properties here.
// Returns the key name as fallback if a translation is missing — surfaces gaps loudly.
public static class Strings
{
    private static readonly ResourceManager Rm =
        new ResourceManager("KeyStats.Properties.Strings", typeof(Strings).Assembly);

    private static string Get(string key) => Rm.GetString(key) ?? key;

    public static string App_Name => Get(nameof(App_Name));
    public static string Common_Cancel => Get(nameof(Common_Cancel));
    public static string Common_Open => Get(nameof(Common_Open));
    public static string Common_Import => Get(nameof(Common_Import));
    public static string Common_Export => Get(nameof(Common_Export));
    public static string Error_AppAlreadyRunning => Get(nameof(Error_AppAlreadyRunning));
    public static string Error_StartupFailedFormat => Get(nameof(Error_StartupFailedFormat));
    public static string Error_AppErrorTitle => Get(nameof(Error_AppErrorTitle));
    public static string Error_ImportInvalidFormat => Get(nameof(Error_ImportInvalidFormat));
    public static string Error_ImportUnsupportedVersion => Get(nameof(Error_ImportUnsupportedVersion));
    public static string Error_ImportEmpty => Get(nameof(Error_ImportEmpty));

    public static string Notif_ThresholdTitle => Get(nameof(Notif_ThresholdTitle));
    public static string Notif_KeyThresholdReachedFormat => Get(nameof(Notif_KeyThresholdReachedFormat));
    public static string Notif_ClickThresholdReachedFormat => Get(nameof(Notif_ClickThresholdReachedFormat));

    public static string Tray_OpenMainWindow => Get(nameof(Tray_OpenMainWindow));
    public static string Tray_Settings => Get(nameof(Tray_Settings));
    public static string Tray_StartAtLogin => Get(nameof(Tray_StartAtLogin));
    public static string Tray_KeyHistory => Get(nameof(Tray_KeyHistory));
    public static string Tray_Quit => Get(nameof(Tray_Quit));

    public static string Toast_ExportSuccess_Title => Get(nameof(Toast_ExportSuccess_Title));
    public static string Toast_ExportSuccess_BodyFormat => Get(nameof(Toast_ExportSuccess_BodyFormat));
    public static string Toast_ExportFailed_Title => Get(nameof(Toast_ExportFailed_Title));
    public static string Toast_ExportFailed_BodyFormat => Get(nameof(Toast_ExportFailed_BodyFormat));
    public static string Toast_ImportSuccess_Title => Get(nameof(Toast_ImportSuccess_Title));
    public static string Toast_ImportSuccess_BodyFormat => Get(nameof(Toast_ImportSuccess_BodyFormat));
    public static string Toast_ImportFailed_Title => Get(nameof(Toast_ImportFailed_Title));
    public static string Toast_ImportFailed_BodyFormat => Get(nameof(Toast_ImportFailed_BodyFormat));
    public static string ImportMode_Overwrite => Get(nameof(ImportMode_Overwrite));
    public static string ImportMode_Merge => Get(nameof(ImportMode_Merge));

    public static string Shortcut_Description => Get(nameof(Shortcut_Description));

    public static string Dialog_ExportTitle => Get(nameof(Dialog_ExportTitle));
    public static string Dialog_ImportTitle => Get(nameof(Dialog_ImportTitle));
    public static string Dialog_JsonFilter => Get(nameof(Dialog_JsonFilter));

    public static string Settings_Language => Get(nameof(Settings_Language));
    public static string Settings_LanguageDescription => Get(nameof(Settings_LanguageDescription));
    public static string Settings_Language_System => Get(nameof(Settings_Language_System));
    public static string Language_RestartPromptTitle => Get(nameof(Language_RestartPromptTitle));
    public static string Language_RestartPromptMessage => Get(nameof(Language_RestartPromptMessage));

    public static string Settings_WindowTitle => Get(nameof(Settings_WindowTitle));
    public static string Settings_HeaderTitle => Get(nameof(Settings_HeaderTitle));
    public static string Settings_HeaderSubtitle => Get(nameof(Settings_HeaderSubtitle));
    public static string Settings_GitHubTooltip => Get(nameof(Settings_GitHubTooltip));
    public static string Settings_DataImportExport => Get(nameof(Settings_DataImportExport));
    public static string Settings_DataImportExportDesc => Get(nameof(Settings_DataImportExportDesc));
    public static string Settings_Notifications => Get(nameof(Settings_Notifications));
    public static string Settings_NotificationsDesc => Get(nameof(Settings_NotificationsDesc));
    public static string Settings_DistanceCalibration => Get(nameof(Settings_DistanceCalibration));
    public static string Settings_DistanceCalibrationDesc => Get(nameof(Settings_DistanceCalibrationDesc));
    public static string Settings_VersionFormat => Get(nameof(Settings_VersionFormat));
    public static string Settings_OpenGitHubFailedMessage => Get(nameof(Settings_OpenGitHubFailedMessage));

    public static string Stats_TodayHeader => Get(nameof(Stats_TodayHeader));
    public static string Stats_KeyPresses => Get(nameof(Stats_KeyPresses));
    public static string Stats_MouseClicks => Get(nameof(Stats_MouseClicks));
    public static string Stats_MouseClickDetail => Get(nameof(Stats_MouseClickDetail));
    public static string Click_Left => Get(nameof(Click_Left));
    public static string Click_Middle => Get(nameof(Click_Middle));
    public static string Click_Right => Get(nameof(Click_Right));
    public static string Click_Back => Get(nameof(Click_Back));
    public static string Click_Forward => Get(nameof(Click_Forward));
    public static string Stats_MouseDistance => Get(nameof(Stats_MouseDistance));
    public static string Stats_ScrollDistance => Get(nameof(Stats_ScrollDistance));
    public static string Stats_KeyBreakdown => Get(nameof(Stats_KeyBreakdown));
    public static string KeyBreakdown_Empty => Get(nameof(KeyBreakdown_Empty));
    public static string Stats_KeyboardHeatmap => Get(nameof(Stats_KeyboardHeatmap));
    public static string Stats_KeyHistory => Get(nameof(Stats_KeyHistory));
    public static string Stats_ActiveApps => Get(nameof(Stats_ActiveApps));
    public static string Stats_AppStatsDetail => Get(nameof(Stats_AppStatsDetail));
    public static string Stats_HistoryHeader => Get(nameof(Stats_HistoryHeader));
    public static string Chart_Line => Get(nameof(Chart_Line));
    public static string Chart_Bar => Get(nameof(Chart_Bar));
    public static string Range_7Days => Get(nameof(Range_7Days));
    public static string Range_30Days => Get(nameof(Range_30Days));
    public static string Metric_Clicks => Get(nameof(Metric_Clicks));
    public static string Metric_Keys => Get(nameof(Metric_Keys));
    public static string Metric_Move => Get(nameof(Metric_Move));
    public static string Metric_Scroll => Get(nameof(Metric_Scroll));
    public static string Stats_PeakKpsTooltipLabel => Get(nameof(Stats_PeakKpsTooltipLabel));
    public static string Stats_PeakCpsTooltipLabel => Get(nameof(Stats_PeakCpsTooltipLabel));

    public static string AppStats_WindowTitle => Get(nameof(AppStats_WindowTitle));
    public static string AppStats_HeaderTitle => Get(nameof(AppStats_HeaderTitle));
    public static string AppStats_HeaderSubtitle => Get(nameof(AppStats_HeaderSubtitle));
    public static string AppStats_RangeToday => Get(nameof(AppStats_RangeToday));
    public static string AppStats_Range7Days => Get(nameof(AppStats_Range7Days));
    public static string AppStats_Range30Days => Get(nameof(AppStats_Range30Days));
    public static string AppStats_RangeAll => Get(nameof(AppStats_RangeAll));
    public static string AppStats_ColumnApp => Get(nameof(AppStats_ColumnApp));
    public static string AppStats_ColumnKeys => Get(nameof(AppStats_ColumnKeys));
    public static string AppStats_ColumnClicks => Get(nameof(AppStats_ColumnClicks));
    public static string AppStats_ColumnScroll => Get(nameof(AppStats_ColumnScroll));
    public static string AppStats_SummaryFormat => Get(nameof(AppStats_SummaryFormat));
    public static string AppStats_Empty => Get(nameof(AppStats_Empty));
    public static string AppStats_UnknownApp => Get(nameof(AppStats_UnknownApp));
    public static string History_TotalFormat => Get(nameof(History_TotalFormat));
    public static string KeyHistory_Empty => Get(nameof(KeyHistory_Empty));
    public static string KeyHistory_SummaryFormat => Get(nameof(KeyHistory_SummaryFormat));
    public static string PieChart_Empty => Get(nameof(PieChart_Empty));
    public static string PieChart_CountFormat => Get(nameof(PieChart_CountFormat));
    public static string PieChart_PercentFormat => Get(nameof(PieChart_PercentFormat));

    public static string Heatmap_WindowTitle => Get(nameof(Heatmap_WindowTitle));
    public static string Heatmap_HeaderTitle => Get(nameof(Heatmap_HeaderTitle));
    public static string Heatmap_HeaderSubtitle => Get(nameof(Heatmap_HeaderSubtitle));
    public static string Heatmap_PrevDay => Get(nameof(Heatmap_PrevDay));
    public static string Heatmap_NextDay => Get(nameof(Heatmap_NextDay));
    public static string Heatmap_BackToToday => Get(nameof(Heatmap_BackToToday));
    public static string Heatmap_NoData => Get(nameof(Heatmap_NoData));
    public static string Heatmap_SummaryFormat => Get(nameof(Heatmap_SummaryFormat));
    public static string Heatmap_DatePickerTooltip => Get(nameof(Heatmap_DatePickerTooltip));

    public static string KeyHistory_WindowTitle => Get(nameof(KeyHistory_WindowTitle));
    public static string KeyHistory_HeaderTitle => Get(nameof(KeyHistory_HeaderTitle));
    public static string KeyHistory_HeaderSubtitle => Get(nameof(KeyHistory_HeaderSubtitle));
    public static string KeyHistory_PieChartTitle => Get(nameof(KeyHistory_PieChartTitle));
    public static string KeyHistory_BarChartTitle => Get(nameof(KeyHistory_BarChartTitle));
    public static string History_Range_Today => Get(nameof(History_Range_Today));
    public static string History_Range_Last7Days => Get(nameof(History_Range_Last7Days));
    public static string History_Range_Last30Days => Get(nameof(History_Range_Last30Days));
    public static string History_Range_All => Get(nameof(History_Range_All));

    public static string Calibration_WindowTitle => Get(nameof(Calibration_WindowTitle));
    public static string Calibration_HeaderTitle => Get(nameof(Calibration_HeaderTitle));
    public static string Calibration_Start => Get(nameof(Calibration_Start));
    public static string Calibration_Finish => Get(nameof(Calibration_Finish));

    public static string Calibration_InstructionEnter => Get(nameof(Calibration_InstructionEnter));
    public static string Calibration_LengthLabel => Get(nameof(Calibration_LengthLabel));
    public static string Calibration_StepsLabel => Get(nameof(Calibration_StepsLabel));
    public static string Calibration_StatusIdle => Get(nameof(Calibration_StatusIdle));
    public static string Calibration_StatusRecording => Get(nameof(Calibration_StatusRecording));
    public static string Calibration_StatusPressEnterFirst => Get(nameof(Calibration_StatusPressEnterFirst));
    public static string Calibration_StatusMovementTooShort => Get(nameof(Calibration_StatusMovementTooShort));
    public static string Calibration_StatusInvalidLength => Get(nameof(Calibration_StatusInvalidLength));
    public static string Calibration_StatusComplete => Get(nameof(Calibration_StatusComplete));
    public static string Calibration_DisplayUnitLabel => Get(nameof(Calibration_DisplayUnitLabel));
    public static string Calibration_UnitAuto => Get(nameof(Calibration_UnitAuto));
    public static string Calibration_UnitPixel => Get(nameof(Calibration_UnitPixel));
    public static string Calibration_CurrentResultLabel => Get(nameof(Calibration_CurrentResultLabel));
    public static string Calibration_PixelsLabelEmpty => Get(nameof(Calibration_PixelsLabelEmpty));
    public static string Calibration_PixelsLabelFormat => Get(nameof(Calibration_PixelsLabelFormat));
    public static string Calibration_ScaleLabelEmpty => Get(nameof(Calibration_ScaleLabelEmpty));
    public static string Calibration_ScaleLabelFormat => Get(nameof(Calibration_ScaleLabelFormat));
    public static string Calibration_TipFooter => Get(nameof(Calibration_TipFooter));

    public static string NotifSettings_WindowTitle => Get(nameof(NotifSettings_WindowTitle));
    public static string NotifSettings_HeaderTitle => Get(nameof(NotifSettings_HeaderTitle));
    public static string NotifSettings_HeaderSubtitle => Get(nameof(NotifSettings_HeaderSubtitle));
    public static string NotifSettings_Enable => Get(nameof(NotifSettings_Enable));
    public static string NotifSettings_KeyCardTitle => Get(nameof(NotifSettings_KeyCardTitle));
    public static string NotifSettings_ClickCardTitle => Get(nameof(NotifSettings_ClickCardTitle));
    public static string NotifSettings_EveryFormat => Get(nameof(NotifSettings_EveryFormat));
    public static string NotifSettings_Hint => Get(nameof(NotifSettings_Hint));

    public static string ImportDialog_HeaderTitle => Get(nameof(ImportDialog_HeaderTitle));
    public static string ImportDialog_Description => Get(nameof(ImportDialog_Description));
    public static string ImportDialog_OverwriteDesc => Get(nameof(ImportDialog_OverwriteDesc));
    public static string ImportDialog_MergeDesc => Get(nameof(ImportDialog_MergeDesc));

    public static string Confirm_DefaultHeaderTitle => Get(nameof(Confirm_DefaultHeaderTitle));
    public static string Confirm_DefaultMessage => Get(nameof(Confirm_DefaultMessage));
    public static string Confirm_DefaultTitle => Get(nameof(Confirm_DefaultTitle));
    public static string Confirm_DefaultConfirm => Get(nameof(Confirm_DefaultConfirm));
}
