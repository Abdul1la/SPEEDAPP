import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'map/map_styles.dart';
import 'screens/map_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppController();
  runApp(SpeedAlertApp(app: app));
  app.init();
}

class SpeedAlertApp extends StatefulWidget {
  const SpeedAlertApp({super.key, required this.app});

  final AppController app;

  @override
  State<SpeedAlertApp> createState() => _SpeedAlertAppState();
}

class _SpeedAlertAppState extends State<SpeedAlertApp> {
  // Light / dark / follow the phone, from the Appearance setting.
  late final ValueNotifier<ThemeMode> _mode = ValueNotifier(_current());

  // Built once so the whole app isn't rebuilt on every GPS update.
  late final Widget _home = MapScreen(app: widget.app);

  ThemeMode _current() => themeModeFor(widget.app.settings.mapLook);

  void _sync() => _mode.value = _current();

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_sync);
  }

  @override
  void dispose() {
    widget.app.removeListener(_sync);
    _mode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _mode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Speed Alert',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        home: _home,
      ),
    );
  }
}
