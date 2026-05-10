// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sprintf/sprintf.dart';
import 'student_editor.dart';
// 仅桌面平台需要 sqflite_common_ffi
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    if (dart.library.io) 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'student_db.dart';
import 'student.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 仅桌面平台需要 window_manager
import 'package:window_manager/window_manager.dart'
    if (dart.library.io) 'package:window_manager/window_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'contributors.dart';

// BIN 1 1111 1111 1111 0000 0000 0000 = DEC 33550336
// 众人将与一人离别，惟其人将觐见奇迹

// 「在彩虹桥的尽头，天空之子将缝补晨昏」
final version = "v3.1.0";
final codename = "SilverWolf";
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面平台初始化 sqflite_ffi 和 window_manager
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setSize(const Size(900, 600));
    await windowManager.setMinimumSize(const Size(600, 400));
    await windowManager.center();
  }
  runApp(MyApp());
}

randomGen(min, max) {
  var x = Random().nextInt(max) + min;
  return x.floor();
}

// 我萤伟大，无需多言
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: Consumer<MyAppState>(
        builder: (context, appState, _) {
          ThemeMode themeMode;
          switch (appState.themeMode) {
            case 0:
              themeMode = ThemeMode.system;
              break;
            case 1:
              themeMode = ThemeMode.light;
              break;
            case 2:
              themeMode = ThemeMode.dark;
              break;
            default:
              themeMode = ThemeMode.system;
          }
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'NamePicker',
            theme: ThemeData(
              useMaterial3: true,
              useSystemColors: true,
              fontFamily: "HarmonyOS_Sans_SC",
              brightness: Brightness.light,
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              useSystemColors: true,
              fontFamily: "HarmonyOS_Sans_SC",
              brightness: Brightness.dark,
            ),
            themeMode: themeMode,
            home: MyHomePage(),
          );
        },
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  MyAppState() {
    _loadSettings();
    _initLists();
  }

  // 多名单支持
  List<ListGroup> lists = [];
  int? currentListId;

  Future<void> _initLists() async {
    lists = await StudentDatabase.instance.readAllLists();
    if (lists.isEmpty) {
      int id = await StudentDatabase.instance.createList('默认名单');
      lists = await StudentDatabase.instance.readAllLists();
      currentListId = id;
    } else {
      currentListId = lists.first.id;
    }
    notifyListeners();
  }

  void setCurrentListId(int? id) {
    currentListId = id;
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    allowRepeat = prefs.getBool('allowRepeat') ?? true;
    themeMode = prefs.getInt('themeMode') ?? 0;
    filterGender = prefs.getString('filterGender') ?? "全部";
    filterNumberType = prefs.getString('filterNumberType') ?? "全部";
    notifyListeners();
  }

  // 是否允许重复抽取
  bool allowRepeat = true;
  // 已抽过学生id列表
  List<int> pickedIds = [];

  void setAllowRepeat(bool value) {
    allowRepeat = value;
    pickedIds.clear();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('allowRepeat', value);
    });
    notifyListeners();
  }

  var current = "别紧张...";
  var history = <String>[];

  void reset() {
    current = "别紧张...";
    history.clear();
    pickedIds.clear();
    notifyListeners();
  }

  GlobalKey? historyListKey;

  // 0: 跟随系统 1: 亮色 2: 暗色
  int themeMode = 0;

  // 筛选条件
  String filterGender = "全部"; // "全部" "男" "女"
  String filterNumberType = "全部"; // "全部" "单号" "双号"

  void setThemeMode(int mode) {
    themeMode = mode;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('themeMode', mode);
    });
    notifyListeners();
  }

  void setFilterGender(String gender) {
    filterGender = gender;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('filterGender', gender);
    });
    notifyListeners();
  }

  void setFilterNumberType(String type) {
    filterNumberType = type;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('filterNumberType', type);
    });
    notifyListeners();
  }

  Future<void> getNextStudent() async {
    // 获取当前名单下所有学生
    if (currentListId == null) {
      current = "请先选择名单";
      notifyListeners();
      return;
    }
    final all = await StudentDatabase.instance.readAll(currentListId!);
    // 按性别筛选
    List<Student> filtered = all;
    if (filterGender != "全部") {
      filtered = filtered.where((s) => s.gender == filterGender).toList();
    }
    // 按学号单双筛选
    if (filterNumberType != "全部") {
      filtered = filtered.where((s) {
        final num = int.tryParse(s.studentId);
        if (num == null) return false;
        if (filterNumberType == "单号") return num % 2 == 1;
        if (filterNumberType == "双号") return num % 2 == 0;
        return true;
      }).toList();
    }
    // 不允许重复时，过滤已抽过
    if (!allowRepeat) {
      filtered = filtered.where((s) => !pickedIds.contains(s.id)).toList();
      if (filtered.isEmpty && all.isNotEmpty) {
        // 所有人都抽过，重置
        pickedIds.clear();
        filtered = all;
        if (filterGender != "全部") {
          filtered = filtered.where((s) => s.gender == filterGender).toList();
        }
        if (filterNumberType != "全部") {
          filtered = filtered.where((s) {
            final num = int.tryParse(s.studentId);
            if (num == null) return false;
            if (filterNumberType == "单号") return num % 2 == 1;
            if (filterNumberType == "双号") return num % 2 == 0;
            return true;
          }).toList();
        }
      }
    }
    if (filtered.isEmpty) {
      current = "无符合条件学生";
    } else {
      final picked = filtered[Random().nextInt(filtered.length)];
      current = "${picked.name}（${picked.studentId}）";
      if (!allowRepeat && picked.id != null) {
        pickedIds.add(picked.id!);
      }
    }
    history.insert(0, current);
    var animatedList = historyListKey?.currentState as AnimatedListState?;
    animatedList?.insertItem(0);
    notifyListeners();
  }
}

class MyHomePage extends StatefulWidget {
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  var selectedIndex = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: selectedIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colorScheme = Theme.of(context).colorScheme;

    final pages = [
      GeneratorPage(),
      NameListPage(),
      SettingsPage(),
      AboutPage(),
    ];

    // The container for the current page, with its background color
    // and subtle switching animation.
    var mainArea = ColoredBox(
      color: colorScheme.surface,
      child: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: pages,
      ),
    );

    return Scaffold(
      body: Column(
        children: [
          if (!kIsWeb && !Platform.isAndroid && !Platform.isIOS)
            CustomTitleBar(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 450) {
                  final colorScheme = Theme.of(context).colorScheme;
                  return Column(
                    children: [
                      Expanded(
                        child: SafeArea(
                          bottom: false,
                          child: mainArea,
                        ),
                      ),
                      Material(
                        color: colorScheme.surface,
                        child: BottomNavigationBar(
                          items: const [
                            BottomNavigationBarItem(
                              icon: Icon(Icons.home),
                              label: '主页',
                            ),
                            BottomNavigationBarItem(
                              icon: Icon(Icons.list),
                              label: '名单',
                            ),
                            BottomNavigationBarItem(
                              icon: Icon(Icons.settings),
                              label: '设置',
                            ),
                            BottomNavigationBarItem(
                              icon: Icon(Icons.info),
                              label: '关于',
                            ),
                          ],
                          currentIndex: selectedIndex,
                          onTap: (value) {
                            setState(() {
                              selectedIndex = value;
                            });
                            _pageController.animateToPage(
                              value,
                              duration: const Duration(milliseconds: 677),
                              curve: Curves.fastLinearToSlowEaseIn,
                            );
                          },
                          backgroundColor: colorScheme.surface,
                          selectedItemColor: colorScheme.primary,
                          unselectedItemColor: colorScheme.onSurface
                              .withOpacity(0.7),
                          type: BottomNavigationBarType.fixed,
                          elevation: 8,
                        ),
                      ),
                    ],
                  );
                } else {
                  return Row(
                    children: [
                      SafeArea(
                        child: NavigationRail(
                          extended: false,
                          labelType: NavigationRailLabelType.all,
                          destinations: [
                            NavigationRailDestination(
                              icon: Icon(Icons.home),
                              label: Text("主页"),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.list),
                              label: Text("名单"),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.settings),
                              label: Text("设置"),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.info),
                              label: Text("关于"),
                            ),
                          ],
                          selectedIndex: selectedIndex,
                          onDestinationSelected: (value) {
                            setState(() {
                              selectedIndex = value;
                            });
                            _pageController.animateToPage(
                              value,
                              duration: const Duration(milliseconds: 677),
                              curve: Curves.fastLinearToSlowEaseIn,
                            );
                          },
                        ),
                      ),
                      Expanded(
                        child: SafeArea(
                          bottom: false,
                          child: mainArea,
                        ),
                      ),
                    ],
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class CustomTitleBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {
        windowManager.startDragging();
      },
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
              colorScheme.primary.withValues(alpha: 0.08),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border(
            bottom: BorderSide(color: colorScheme.outlineVariant, width: 1),
          ),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            SizedBox(width: (!kIsWeb && Platform.isMacOS) ? 76 : 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/NamePicker.png',
                width: 28,
                height: 28,
              ),
            ),
            SizedBox(width: 10),
            Text(
              'NamePicker',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                fontFamily: "HarmonyOS_Sans_SC",
                color: colorScheme.primary,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(width: 8),
            Container(width: 1, height: 20, color: colorScheme.outlineVariant),
            Spacer(),
            if (!kIsWeb && !Platform.isMacOS) ...[
              _TitleBarButton(
                icon: Icons.minimize,
                tooltip: '最小化',
                onTap: () => windowManager.minimize(),
                color: colorScheme.onSurfaceVariant,
              ),
              _TitleBarButton(
                icon: Icons.crop_square,
                tooltip: '最大化/还原',
                onTap: () async {
                  bool isMax = await windowManager.isMaximized();
                  if (isMax) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                },
                color: colorScheme.onSurfaceVariant,
              ),
              _TitleBarButton(
                icon: Icons.close,
                tooltip: '关闭',
                onTap: () => windowManager.close(),
                color: colorScheme.error,
                hoverColor: colorScheme.errorContainer,
              ),
              SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _TitleBarButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;
  final Color? hoverColor;
  const _TitleBarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.color,
    this.hoverColor,
  });

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: _hovering
                ? (widget.hoverColor ?? Theme.of(context).colorScheme.primary
                    ..withValues(alpha: 0.08))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          width: 32,
          height: 32,
          child: Icon(widget.icon, size: 18, color: widget.color),
        ),
      ),
    );
  }
}

class GeneratorPage extends StatefulWidget {
  @override
  State<GeneratorPage> createState() => _GeneratorPageState();
}

class _GeneratorPageState extends State<GeneratorPage> {
  int _pickCount = 1;

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();
    var colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 600;
            final displayCard = _buildDisplayCard(appState, colorScheme, isWide: isWide);
            final optionsCard = _buildOptionsCard(appState, colorScheme);

            if (isWide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: displayCard),
                  const SizedBox(width: 16),
                  Expanded(flex: 4, child: optionsCard),
                ],
              );
            } else {
              return SingleChildScrollView(
                child: Column(
                  children: [
                    displayCard,
                    const SizedBox(height: 16),
                    optionsCard,
                  ],
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildDisplayCard(MyAppState appState, ColorScheme colorScheme, {required bool isWide}) {
    final theme = Theme.of(context);
    final currentText = appState.current;
    final isDefault = currentText == "别紧张...";
    final isWarning = currentText == "无符合条件学生" || currentText == "请先选择名单";

    Color textColor;
    FontWeight fontWeight;
    if (isDefault) {
      textColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
      fontWeight = FontWeight.w300;
    } else if (isWarning) {
      textColor = colorScheme.error;
      fontWeight = FontWeight.w500;
    } else {
      textColor = colorScheme.primary;
      fontWeight = FontWeight.w700;
    }

    final recentHistory = appState.history.take(5).toList();

    final mainResult = Center(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            currentText,
            textAlign: TextAlign.center,
            style: theme.textTheme.displayLarge?.copyWith(
              color: textColor,
              fontWeight: fontWeight,
              fontFamily: "HarmonyOS_Sans_SC",
            ),
          ),
        ),
      ),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colorScheme.outlineVariant, width: 1),
      ),
      color: colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_outline, color: colorScheme.primary, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        '抽选结果',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => appState.reset(),
                  icon: Icon(Icons.restart_alt),
                  tooltip: '重置',
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (isWide) Expanded(child: mainResult) else SizedBox(height: 180, child: mainResult),
            if (recentHistory.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  itemCount: recentHistory.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
                  itemBuilder: (context, idx) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: colorScheme.primaryContainer,
                            child: Text(
                              '${idx + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              recentHistory[idx],
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOptionsCard(MyAppState appState, ColorScheme colorScheme) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colorScheme.outlineVariant, width: 1),
      ),
      color: colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, color: colorScheme.primary, size: 20),
                const SizedBox(width: 6),
                Text(
                  '抽选选项',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // 名单选择
            Row(
              children: [
                Icon(Icons.list, color: colorScheme.primary, size: 18),
                const SizedBox(width: 8),
                Text('名单：', style: theme.textTheme.bodyMedium),
                Expanded(
                  child: DropdownButton<int>(
                    value: appState.currentListId,
                    isExpanded: true,
                    items: appState.lists
                        .map((l) => DropdownMenuItem(value: l.id, child: Text(l.name)))
                        .toList(),
                    onChanged: (id) => appState.setCurrentListId(id),
                  ),
                ),
                IconButton(
                  onPressed: appState._initLists,
                  icon: Icon(Icons.replay, size: 18),
                  tooltip: '刷新名单列表',
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // 筛选条件
            Row(
              children: [
                Icon(Icons.filter_alt_outlined, color: colorScheme.primary, size: 18),
                const SizedBox(width: 8),
                Text('筛选条件', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Row(
                children: [
                  Text('性别：', style: theme.textTheme.bodySmall),
                  DropdownButton<String>(
                    value: appState.filterGender,
                    items: ['全部', '男', '女']
                        .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                        .toList(),
                    onChanged: (v) => appState.setFilterGender(v!),
                  ),
                  const SizedBox(width: 12),
                  Text('学号：', style: theme.textTheme.bodySmall),
                  DropdownButton<String>(
                    value: appState.filterNumberType,
                    items: ['全部', '单号', '双号']
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (v) => appState.setFilterNumberType(v!),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // 抽选人数
            Row(
              children: [
                Icon(Icons.numbers, color: colorScheme.primary, size: 18),
                const SizedBox(width: 8),
                Text('抽选人数：', style: theme.textTheme.bodyMedium),
                const Spacer(),
                IconButton(
                  onPressed: _pickCount <= 1
                      ? null
                      : () => setState(() => _pickCount -= 1),
                  icon: Icon(Icons.remove_circle_outline),
                  color: colorScheme.primary,
                ),
                Text(
                  '$_pickCount',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                IconButton(
                  onPressed: () => setState(() => _pickCount += 1),
                  icon: Icon(Icons.add_circle_outline),
                  color: colorScheme.primary,
                ),
              ],
            ),
            const SizedBox(height: 24),
            // 抽选按钮
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.casino_outlined),
                onPressed: () async {
                  for (int i = 0; i < _pickCount; i++) {
                    await appState.getNextStudent();
                  }
                },
                label: const Text('抽选'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BigCard extends StatelessWidget {
  const BigCard({Key? key, required this.pair}) : super(key: key);

  final String pair;

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var style = theme.textTheme.displayMedium!.copyWith(
      color: theme.colorScheme.onPrimary,
    );

    return Card(
      color: theme.colorScheme.primary,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: AnimatedSize(
          duration: Duration(milliseconds: 200),
          // Make sure that the compound word wraps correctly when the window
          // is too narrow.
          child: MergeSemantics(
            child: Wrap(
              children: [
                Text(
                  pair,
                  style: style.copyWith(
                    fontWeight: FontWeight.w200,
                    fontFamily: "HarmonyOS_Sans_SC",
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NameListPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StudentEditorPage();
  }
}

class SettingsPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var appState = context.watch<MyAppState>();
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
          child: Text(
            '设置',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.brightness_6_outlined),
          title: Text("主题模式"),
          subtitle: Text("选择亮色、暗色或跟随系统主题"),
          trailing: DropdownButton<int>(
            value: appState.themeMode,
            items: const [
              DropdownMenuItem(value: 0, child: Text("跟随系统")),
              DropdownMenuItem(value: 1, child: Text("亮色")),
              DropdownMenuItem(value: 2, child: Text("暗色")),
            ],
            onChanged: (v) {
              if (v != null) appState.setThemeMode(v);
            },
          ),
        ),
        ListTile(
          leading: Icon(Icons.repeat),
          title: Text("允许重复抽取"),
          subtitle: Text("关闭后，所有人都抽过才会重置名单"),
          trailing: Switch(
            value: appState.allowRepeat,
            onChanged: (v) => appState.setAllowRepeat(v),
          ),
        ),
      ],
    );
  }
}

class AboutPage extends StatefulWidget {
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  bool _contributorsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final hasMore = contributors.length > 3;
    final displayContributors =
        _contributorsExpanded ? contributors : contributors.take(3).toList();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Center(
              child: SvgPicture.asset(
                'assets/NamePicker-64rad.svg',
                width: 96,
                height: 96,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'NamePicker',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              "$version · $codename",
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: colorScheme.outlineVariant, width: 1),
                ),
                color: colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: colorScheme.primaryContainer,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: Image.asset('assets/avaters/lhgser.jpg', width: 48, height: 48),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('灵魂歌手er', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                              Text('开发者', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "「这次能让我玩得开心点吗？」",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            const url = 'https://github.com/NamePickerOrg/NamePicker';
                            final uri = Uri.parse(url);
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri);
                            }
                          },
                          icon: Icon(Icons.open_in_new),
                          label: Text('GitHub'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: colorScheme.outlineVariant, width: 1),
                ),
                color: colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('贡献者', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      if (contributors.isEmpty)
                        Text('暂无贡献者', style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant))
                      else ...[
                        for (final c in displayContributors)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Icon(Icons.person, size: 20, color: colorScheme.onSurfaceVariant),
                                const SizedBox(width: 12),
                                Text(c, style: theme.textTheme.bodyMedium),
                              ],
                            ),
                          ),
                        if (hasMore)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => setState(() => _contributorsExpanded = !_contributorsExpanded),
                              child: Text(_contributorsExpanded ? '收起' : '展开全部 (${contributors.length})'),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "© 2025-2026 NamePickerOrg",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HistoryListView extends StatefulWidget {
  const HistoryListView({Key? key}) : super(key: key);

  @override
  State<HistoryListView> createState() => _HistoryListViewState();
}

class _HistoryListViewState extends State<HistoryListView> {
  /// Needed so that [MyAppState] can tell [AnimatedList] below to animate
  /// new items.
  final _key = GlobalKey();

  /// Used to "fade out" the history items at the top, to suggest continuation.
  static const Gradient _maskingGradient = LinearGradient(
    // This gradient goes from fully transparent to fully opaque black...
    colors: [Colors.transparent, Colors.black],
    // ... from the top (transparent) to half (0.5) of the way to the bottom.
    stops: [0.0, 0.5],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    appState.historyListKey = _key;

    return ShaderMask(
      shaderCallback: (bounds) => _maskingGradient.createShader(bounds),
      // This blend mode takes the opacity of the shader (i.e. our gradient)
      // and applies it to the destination (i.e. our animated list).
      blendMode: BlendMode.dstIn,
      child: AnimatedList(
        key: _key,
        reverse: true,
        padding: EdgeInsets.only(top: 200),
        initialItemCount: appState.history.length,
        itemBuilder: (context, index, animation) {
          final pair = appState.history[index];
          return SizeTransition(
            sizeFactor: animation,
            child: Center(child: HistoryCard(pair: pair)),
          );
        },
      ),
    );
  }
}

class HistoryCard extends StatelessWidget {
  const HistoryCard({super.key, required this.pair});

  final String pair;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(5.0),
      child: Card(child: Text(sprintf("  %s  ", [pair]), semanticsLabel: pair)),
    );
  }
}

// 成为英雄吧，救世主。
