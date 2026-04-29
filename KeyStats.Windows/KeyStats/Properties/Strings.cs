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
    public static string Common_Ok => Get(nameof(Common_Ok));
    public static string Common_Cancel => Get(nameof(Common_Cancel));
    public static string Common_Close => Get(nameof(Common_Close));
    public static string Common_Retry => Get(nameof(Common_Retry));
    public static string Common_Open => Get(nameof(Common_Open));
    public static string Common_Import => Get(nameof(Common_Import));
    public static string Common_Export => Get(nameof(Common_Export));
    public static string Error_AppAlreadyRunning => Get(nameof(Error_AppAlreadyRunning));
    public static string Error_StartupFailedFormat => Get(nameof(Error_StartupFailedFormat));
    public static string Error_AppErrorTitle => Get(nameof(Error_AppErrorTitle));

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
}
