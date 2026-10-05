using System.Windows;

namespace ContextOS.Windows;

public partial class MainWindow : Window
{
    internal int InformationTabCount => InformationTabs.Items.Count;
    internal MainWindow(DashboardViewModel model) { InitializeComponent(); DataContext = model; }
    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        if (DataContext is DashboardViewModel model) await model.InspectAsync();
    }
}
