using System.Collections;
using System.Windows;
using System.Windows.Controls;

namespace KeyStats.Views.Controls;

public partial class KeyBreakdownControl : System.Windows.Controls.UserControl
{
    public static readonly DependencyProperty Column1ItemsProperty =
        DependencyProperty.Register(nameof(Column1Items), typeof(IEnumerable), typeof(KeyBreakdownControl),
            new PropertyMetadata(null, OnItemsChanged));

    public static readonly DependencyProperty Column2ItemsProperty =
        DependencyProperty.Register(nameof(Column2Items), typeof(IEnumerable), typeof(KeyBreakdownControl),
            new PropertyMetadata(null, OnItemsChanged));

    public static readonly DependencyProperty Column3ItemsProperty =
        DependencyProperty.Register(nameof(Column3Items), typeof(IEnumerable), typeof(KeyBreakdownControl),
            new PropertyMetadata(null, OnItemsChanged));

    public IEnumerable? Column1Items
    {
        get => (IEnumerable?)GetValue(Column1ItemsProperty);
        set => SetValue(Column1ItemsProperty, value);
    }

    public IEnumerable? Column2Items
    {
        get => (IEnumerable?)GetValue(Column2ItemsProperty);
        set => SetValue(Column2ItemsProperty, value);
    }

    public IEnumerable? Column3Items
    {
        get => (IEnumerable?)GetValue(Column3ItemsProperty);
        set => SetValue(Column3ItemsProperty, value);
    }

    public KeyBreakdownControl()
    {
        InitializeComponent();
    }

    private static void OnItemsChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is KeyBreakdownControl control)
        {
            control.UpdateItemsSources();
        }
    }

    private void UpdateItemsSources()
    {
        Column1.ItemsSource = Column1Items;
        Column2.ItemsSource = Column2Items;
        Column3.ItemsSource = Column3Items;

        var hasItems = (Column1Items?.Cast<object>().Any() ?? false) ||
                       (Column2Items?.Cast<object>().Any() ?? false) ||
                       (Column3Items?.Cast<object>().Any() ?? false);

        EmptyText.Visibility = hasItems ? Visibility.Collapsed : Visibility.Visible;
    }
}
