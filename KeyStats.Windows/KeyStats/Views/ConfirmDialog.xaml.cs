using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using KeyStats.Helpers;

namespace KeyStats.Views
{
    public partial class ConfirmDialog : Window
    {
        public enum DialogIcon
        {
            Warning,
            Info,
            Error,
            Question
        }

        public bool Confirmed { get; private set; }

        public ConfirmDialog()
        {
            InitializeComponent();
            Loaded += OnLoaded;
            Closed += OnClosed;
            ThemeManager.Instance.ThemeChanged += OnThemeChanged;

            // Allow dragging the window
            MouseLeftButtonDown += (s, e) =>
            {
                if (e.LeftButton == MouseButtonState.Pressed)
                    DragMove();
            };

            // ESC to close
            KeyDown += (s, e) =>
            {
                if (e.Key == Key.Escape)
                {
                    Confirmed = false;
                    Close();
                }
            };
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            ApplyWindowBackdrop();
        }

        private void OnClosed(object? sender, EventArgs e)
        {
            ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        }

        private void OnThemeChanged()
        {
            Dispatcher.BeginInvoke(new Action(ApplyWindowBackdrop));
        }

        private void ApplyWindowBackdrop()
        {
            WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);
        }

        public static bool Show(
            string message,
            string title = "确认",
            string confirmText = "确定",
            string cancelText = "取消",
            DialogIcon icon = DialogIcon.Warning,
            Window? owner = null)
        {
            var dialog = new ConfirmDialog();
            dialog.TitleText.Text = title;
            dialog.MessageText.Text = message;
            dialog.ConfirmButton.Content = confirmText;
            dialog.CancelButton.Content = cancelText;
            dialog.SetIcon(icon);

            if (owner != null)
            {
                dialog.Owner = owner;
                dialog.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            }

            dialog.ShowDialog();
            return dialog.Confirmed;
        }

        private void SetIcon(DialogIcon icon)
        {
            switch (icon)
            {
                case DialogIcon.Warning:
                    IconBorder.Background = new SolidColorBrush(Color.FromRgb(0xFF, 0xF4, 0xCE));
                    IconText.Foreground = new SolidColorBrush(Color.FromRgb(0x9D, 0x5D, 0x00));
                    IconText.Text = "\uE7BA"; // Warning icon
                    break;
                case DialogIcon.Info:
                    IconBorder.Background = new SolidColorBrush(Color.FromRgb(0xDE, 0xEC, 0xF9));
                    IconText.Foreground = new SolidColorBrush(Color.FromRgb(0x00, 0x67, 0xC0));
                    IconText.Text = "\uE946"; // Info icon
                    break;
                case DialogIcon.Error:
                    IconBorder.Background = new SolidColorBrush(Color.FromRgb(0xFD, 0xE7, 0xE9));
                    IconText.Foreground = new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C));
                    IconText.Text = "\uEA39"; // Error icon
                    break;
                case DialogIcon.Question:
                    IconBorder.Background = new SolidColorBrush(Color.FromRgb(0xDE, 0xEC, 0xF9));
                    IconText.Foreground = new SolidColorBrush(Color.FromRgb(0x00, 0x67, 0xC0));
                    IconText.Text = "\uE897"; // Question icon
                    break;
            }
        }

        private void ConfirmButton_Click(object sender, RoutedEventArgs e)
        {
            Confirmed = true;
            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            Confirmed = false;
            Close();
        }
    }
}
