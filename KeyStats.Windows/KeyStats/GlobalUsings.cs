// Resolve WPF vs Windows Forms namespace conflicts
// Alias WPF types to take precedence in this project

global using Application = System.Windows.Application;
global using MessageBox = System.Windows.MessageBox;
global using MessageBoxButton = System.Windows.MessageBoxButton;
global using MessageBoxImage = System.Windows.MessageBoxImage;
global using MessageBoxResult = System.Windows.MessageBoxResult;
global using Binding = System.Windows.Data.Binding;
global using SystemColors = System.Windows.SystemColors;
global using Size = System.Windows.Size;
global using Point = System.Windows.Point;
global using Rectangle = System.Windows.Shapes.Rectangle;

// Media types
global using Color = System.Windows.Media.Color;
global using Brush = System.Windows.Media.Brush;
global using SolidColorBrush = System.Windows.Media.SolidColorBrush;
