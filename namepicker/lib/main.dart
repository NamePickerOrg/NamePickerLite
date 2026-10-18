// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

// 我萤伟大，无需多言
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      // 只监听主题模式，抽选结果变化不再重建整个 MaterialApp。
      child: Selector<MyAppState, int>(
        selector: (context, appState) => appState.themeMode,
        builder: (context, storedThemeMode, _) {
          final themeMode = switch (storedThemeMode) {
            1 => ThemeMode.light,
            2 => ThemeMode.dark,
            _ => ThemeMode.system,
          };
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

/// 抽选结果的语义状态，界面按状态渲染，不靠文案相等判断。
enum DrawStatus { idle, ready, noList, noCandidates, error }

/// 一次抽选结果中单个学生的不可变快照，后续编辑不会改到历史记录。
class PickedStudent {
  final int id;
  final int listId;
  final String name;
  final String studentNumber;

  const PickedStudent({
    required this.id,
    required this.listId,
    required this.name,
    required this.studentNumber,
  });

  factory PickedStudent.fromStudent(Student student, int listId) {
    return PickedStudent(
      id: student.id!,
      listId: student.listId ?? listId,
      name: student.name,
      studentNumber: student.studentId,
    );
  }
}

class MyAppState extends ChangeNotifier {
  MyAppState({
    Future<List<Student>> Function(int listId)? readStudents,
    Random? random,
  })  : _readStudentsFn = readStudents ?? StudentDatabase.instance.readAll,
        _random = random ?? Random() {
    _initialization = _initialize();
  }

  final Future<List<Student>> Function(int listId) _readStudentsFn;
  final Random _random;

  Future<void>? _initialization;
  bool _disposed = false;

  /// 初始化是否成功完成；未完成时禁止抽选、编辑与名单管理。
  bool isReady = false;
  String? initializationError;

  // 多名单支持：全局唯一起源，编辑页与抽选页都读取这里
  List<ListGroup> lists = [];
  int? currentListId;

  /// 名单内容版本号；同一名单内增删改后递增，编辑页据此刷新。
  int rosterRevision = 0;

  /// 是否正在创建/重命名/删除名单。
  bool isManagingLists = false;

  /// 抽选代际：重置、换名单、筛选变化、名单内容变化时递增，
  /// 让在途查询在提交前发现自己已经过期。
  int _generation = 0;

  /// 名单重载请求序号：只有最后发出的重载可以提交。
  int _reloadRequest = 0;

  /// 初始化设置与名单，成功后复用同一个 Future；失败清除缓存等待重试。
  Future<void> initialize() {
    if (isReady) return Future<void>.value();
    final pending = _initialization;
    if (pending != null) return pending;
    final retry = _initialize();
    _initialization = retry;
    return retry;
  }

  Future<void> _initialize() async {
    initializationError = null;
    try {
      await _loadSettings();
      await _reloadLists();
      if (_disposed) return;
      isReady = true;
    } catch (_) {
      if (_disposed) return;
      isReady = false;
      initializationError = '初始化失败';
      _initialization = null;
    }
    _notify();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    allowRepeat = prefs.getBool('allowRepeat') ?? true;
    final storedTheme = prefs.getInt('themeMode') ?? 0;
    themeMode = (storedTheme >= 0 && storedTheme <= 2) ? storedTheme : 0;
    final storedGender = prefs.getString('filterGender') ?? "全部";
    filterGender = genders.contains(storedGender) ? storedGender : "全部";
    final storedNumberType = prefs.getString('filterNumberType') ?? "全部";
    filterNumberType =
        numberTypes.contains(storedNumberType) ? storedNumberType : "全部";
  }

  Future<void> _reloadLists({int? preferredListId}) async {
    final request = ++_reloadRequest;
    final loaded = await StudentDatabase.instance.readAllLists();
    if (_disposed || request != _reloadRequest) return;
    lists = loaded;
    // 以提交时最新的选择为准，避免旧快照抢回选择。
    final desired = preferredListId ?? currentListId;
    final desiredExists = desired != null && loaded.any((l) => l.id == desired);
    final target = desiredExists ? desired : loaded.first.id;
    if (target != currentListId) {
      currentListId = target;
      _generation++;
      _clearDrawSession();
    }
    _notify();
  }

  /// 重新从数据库读取名单，并保证 [currentListId] 始终指向存在的名单。
  Future<void> refreshLists({int? preferredListId}) async {
    await initialize();
    _requireReady();
    await _reloadLists(preferredListId: preferredListId);
  }

  void _requireReady() {
    if (!isReady) throw StateError('初始化失败');
  }

  Future<T> _withListManagement<T>(Future<T> Function() action) async {
    await initialize();
    _requireReady();
    if (isManagingLists) throw StateError('名单操作进行中');
    isManagingLists = true;
    _notify();
    try {
      return await action();
    } finally {
      isManagingLists = false;
      _notify();
    }
  }

  Future<int> createList(String name) => _withListManagement(() async {
        final id = await StudentDatabase.instance.createList(name);
        await _reloadLists(preferredListId: id);
        return id;
      });

  Future<void> renameList(ListGroup list) => _withListManagement(() async {
        await StudentDatabase.instance.updateList(list);
        await _reloadLists();
      });

  /// 删除名单。至少保留一个名单；删除当前名单时回退到 ID 最小的名单。
  Future<bool> deleteList(int id) => _withListManagement(() async {
        final affected = await StudentDatabase.instance.deleteList(id);
        if (affected == 0) return false;
        await _reloadLists();
        return true;
      });

  /// 只接受 [lists] 中存在的非空 ID；未知 ID 不改变当前选择。
  void setCurrentListId(int? id) {
    if (!isReady || id == null) return;
    if (!lists.any((l) => l.id == id)) return;
    if (isManagingLists) throw StateError('名单操作进行中');
    if (id == currentListId) return;
    currentListId = id;
    _generation++;
    _clearDrawSession();
    _notify();
  }

  /// 读取指定名单的学生；编辑页与抽选共用同一个可注入入口。
  Future<List<Student>> readStudents(int listId) => _readStudentsFn(listId);

  // 是否允许重复抽取
  bool allowRepeat = true;
  // 本轮已抽过的学生 id
  Set<int> pickedIds = <int>{};

  bool isDrawing = false;
  DrawStatus drawStatus = DrawStatus.idle;
  /// 最近一次成功批次的结果，按抽出顺序排列。
  List<PickedStudent> latestDraw = <PickedStudent>[];
  /// 全部成功抽选记录，最新的在前。
  List<PickedStudent> history = <PickedStudent>[];

  // 0: 跟随系统 1: 亮色 2: 暗色
  int themeMode = 0;

  // 筛选条件
  String filterGender = "全部"; // "全部" "男" "女"
  String filterNumberType = "全部"; // "全部" "单号" "双号"

  static const List<String> genders = ["全部", "男", "女"];
  static const List<String> numberTypes = ["全部", "单号", "双号"];

  void setAllowRepeat(bool value) {
    if (allowRepeat == value) return;
    allowRepeat = value;
    pickedIds = <int>{};
    _invalidateDraw();
    _persist((prefs) => prefs.setBool('allowRepeat', value));
    _notify();
  }

  void reset() {
    _generation++;
    _clearDrawSession();
    _notify();
  }

  void setThemeMode(int mode) {
    if (mode < 0 || mode > 2 || themeMode == mode) return;
    themeMode = mode;
    _persist((prefs) => prefs.setInt('themeMode', mode));
    _notify();
  }

  void setFilterGender(String gender) {
    if (!genders.contains(gender) || filterGender == gender) return;
    filterGender = gender;
    _invalidateDraw();
    _persist((prefs) => prefs.setString('filterGender', gender));
    _notify();
  }

  void setFilterNumberType(String type) {
    if (!numberTypes.contains(type) || filterNumberType == type) return;
    filterNumberType = type;
    _invalidateDraw();
    _persist((prefs) => prefs.setString('filterNumberType', type));
    _notify();
  }

  /// 名单内容变化后调用一次；当前名单的抽选会话随之失效。
  void studentsChanged(int listId) {
    rosterRevision++;
    if (listId == currentListId) {
      _generation++;
      _clearDrawSession();
    }
    _notify();
  }

  /// 一次读库、一次提交，连续抽选 [count] 次。
  ///
  /// 允许重复时每次都从候选里独立均匀抽取；关闭重复时从本轮未抽过的
  /// 候选池取，池耗尽后自动开始新一轮，继续完成同一批次数。
  Future<void> drawStudents(int count) async {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', '必须大于0');
    }
    if (isDrawing) return;

    isDrawing = true;
    _notify();
    try {
      await initialize();
      if (_disposed) return;
      final generation = _generation;
      if (!isReady) {
        _setDrawFailure(DrawStatus.error);
        return;
      }
      final listId = currentListId;
      if (listId == null) {
        _setDrawFailure(DrawStatus.noList);
        return;
      }
      final gender = filterGender;
      final numberType = filterNumberType;
      final allowRepeatNow = allowRepeat;

      List<Student> all;
      try {
        all = await readStudents(listId);
      } catch (_) {
        if (_isStale(generation, listId)) return;
        _setDrawFailure(DrawStatus.error);
        return;
      }
      if (_isStale(generation, listId)) return;

      final eligible = _filterStudents(
        all,
        gender: gender,
        numberType: numberType,
      );
      if (eligible.isEmpty) {
        _setDrawFailure(DrawStatus.noCandidates);
        return;
      }

      final picked = <Student>[];
      final pickedThisRound = <int>{};
      if (allowRepeatNow) {
        for (var i = 0; i < count; i++) {
          picked.add(eligible[_random.nextInt(eligible.length)]);
        }
      } else {
        pickedThisRound.addAll(pickedIds);
        var pool =
            eligible.where((s) => !pickedThisRound.contains(s.id)).toList();
        if (pool.isEmpty) {
          // 本轮已经抽完，自动开始新一轮。
          pickedThisRound.clear();
          pool = List<Student>.of(eligible);
        }
        for (var i = 0; i < count; i++) {
          if (pool.isEmpty) {
            // 同一批次跨轮：清空本轮记录后重新填入候选。
            pickedThisRound.clear();
            pool = List<Student>.of(eligible);
          }
          final index = _random.nextInt(pool.length);
          final student = pool[index];
          pool[index] = pool.last;
          pool.removeLast();
          pickedThisRound.add(student.id!);
          picked.add(student);
        }
      }

      latestDraw = [
        for (final student in picked)
          PickedStudent.fromStudent(student, listId),
      ];
      history = [...latestDraw.reversed, ...history];
      pickedIds = allowRepeatNow ? <int>{} : pickedThisRound;
      drawStatus = DrawStatus.ready;
    } finally {
      isDrawing = false;
      _notify();
    }
  }

  bool _isStale(int generation, int listId) =>
      _disposed || generation != _generation || listId != currentListId;

  List<Student> _filterStudents(
    List<Student> source, {
    required String gender,
    required String numberType,
  }) {
    return source.where((s) {
      if (s.id == null) return false;
      if (gender != "全部" && s.gender != gender) return false;
      if (numberType != "全部") {
        final number = int.tryParse(s.studentId);
        if (number == null) return false;
        if (numberType == "单号") return number % 2 == 1;
        if (numberType == "双号") return number % 2 == 0;
      }
      return true;
    }).toList();
  }

  void _setDrawFailure(DrawStatus status) {
    latestDraw = <PickedStudent>[];
    drawStatus = status;
  }

  void _clearDrawSession() {
    drawStatus = DrawStatus.idle;
    latestDraw = <PickedStudent>[];
    history = <PickedStudent>[];
    pickedIds = <int>{};
  }

  void _invalidateDraw() {
    _generation++;
    drawStatus = DrawStatus.idle;
    latestDraw = <PickedStudent>[];
  }

  void _persist(Future<Object?> Function(SharedPreferences prefs) write) {
    SharedPreferences.getInstance().then(write).ignore();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

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
    final appState = context.watch<MyAppState>();

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
      child: appState.isReady
          ? PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: pages,
            )
          : _buildInitializationGate(appState),
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
                  return Column(
                    children: [
                      Expanded(child: SafeArea(bottom: false, child: mainArea)),
                      NavigationBar(
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
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home_outlined),
                            selectedIcon: Icon(Icons.home),
                            label: '主页',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.list_outlined),
                            selectedIcon: Icon(Icons.list),
                            label: '名单',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.settings_outlined),
                            selectedIcon: Icon(Icons.settings),
                            label: '设置',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.info_outline),
                            selectedIcon: Icon(Icons.info),
                            label: '关于',
                          ),
                        ],
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
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.home_outlined),
                              selectedIcon: Icon(Icons.home),
                              label: Text("主页"),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.list_outlined),
                              selectedIcon: Icon(Icons.list),
                              label: Text("名单"),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.settings_outlined),
                              selectedIcon: Icon(Icons.settings),
                              label: Text("设置"),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.info_outline),
                              selectedIcon: Icon(Icons.info),
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
                      Expanded(child: SafeArea(bottom: false, child: mainArea)),
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

  Widget _buildInitializationGate(MyAppState appState) {
    if (appState.initializationError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              appState.initializationError!,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: appState.initialize,
              child: const Text('重试'),
            ),
          ],
        ),
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
            final displayCard = _buildDisplayCard(
              appState,
              colorScheme,
              isWide: isWide,
            );
            final optionsCard = _buildOptionsCard(
              appState,
              colorScheme,
              isWide: isWide,
            );

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

  Widget _buildDisplayCard(
    MyAppState appState,
    ColorScheme colorScheme, {
    required bool isWide,
  }) {
    final theme = Theme.of(context);

    // 结果文案只由状态决定，不再依赖文案相等比较。
    final String currentText;
    var isDefault = false;
    var isWarning = false;
    switch (appState.drawStatus) {
      case DrawStatus.ready:
        final latest = appState.latestDraw;
        currentText = latest.isEmpty
            ? "别紧张..."
            : '${latest.last.name}（${latest.last.studentNumber}）';
        isDefault = latest.isEmpty;
      case DrawStatus.noList:
        currentText = "请先选择名单";
        isWarning = true;
      case DrawStatus.noCandidates:
        currentText = "无符合条件学生";
        isWarning = true;
      case DrawStatus.error:
        currentText = "抽选失败，请重试";
        isWarning = true;
      case DrawStatus.idle:
        currentText = "别紧张...";
        isDefault = true;
    }

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

    final recentHistory = appState.history
        .take(5)
        .map((s) => '${s.name}（${s.studentNumber}）')
        .toList();

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
                      Icon(
                        Icons.person_outline,
                        color: colorScheme.primary,
                        size: 20,
                      ),
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
            if (isWide)
              Expanded(child: mainResult)
            else
              SizedBox(height: 180, child: mainResult),
            if (recentHistory.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  itemCount: recentHistory.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
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

  Widget _buildOptionsCard(
    MyAppState appState,
    ColorScheme colorScheme, {
    required bool isWide,
  }) {
    final theme = Theme.of(context);
    final canDraw = appState.isReady && !appState.isDrawing;
    // 人数加减按钮使用紧凑的 36×36 容器，图标仍为 24dp。
    final stepperButtonStyle = IconButton.styleFrom(
      fixedSize: const Size(36, 36),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    final controls = <Widget>[
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
      // 名单选择：MD3 展示型下拉菜单（exposed dropdown menu）。
      DropdownMenu<int>(
        initialSelection: appState.currentListId,
        enabled: appState.isReady && !appState.isManagingLists,
        selectOnly: true,
        expandedInsets: EdgeInsets.zero,
        label: const Text('名单'),
        leadingIcon: Icon(
          Icons.list,
          color: colorScheme.primary,
          size: 20,
        ),
        dropdownMenuEntries: [
          for (final list in appState.lists)
            if (list.id != null)
              DropdownMenuEntry(value: list.id!, label: list.name),
        ],
        onSelected: (id) => appState.setCurrentListId(id),
      ),
      const SizedBox(height: 24),
      // 筛选条件
      Row(
        children: [
          Icon(
            Icons.filter_alt_outlined,
            color: colorScheme.primary,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            '筛选条件',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final genderMenu = DropdownMenu<String>(
            initialSelection: appState.filterGender,
            selectOnly: true,
            expandedInsets: EdgeInsets.zero,
            label: const Text('性别'),
            dropdownMenuEntries: [
              for (final gender in MyAppState.genders)
                DropdownMenuEntry(value: gender, label: gender),
            ],
            onSelected: (value) {
              if (value != null) appState.setFilterGender(value);
            },
          );
          final numberMenu = DropdownMenu<String>(
            initialSelection: appState.filterNumberType,
            selectOnly: true,
            expandedInsets: EdgeInsets.zero,
            label: const Text('学号'),
            dropdownMenuEntries: [
              for (final type in MyAppState.numberTypes)
                DropdownMenuEntry(value: type, label: type),
            ],
            onSelected: (value) {
              if (value != null) appState.setFilterNumberType(value);
            },
          );
          // 窄布局下两个下拉框并排会把选中文本挤掉，改为纵向排列。
          if (constraints.maxWidth < 260) {
            return Column(
              children: [
                genderMenu,
                const SizedBox(height: 12),
                numberMenu,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: genderMenu),
              const SizedBox(width: 12),
              Expanded(child: numberMenu),
            ],
          );
        },
      ),
      const SizedBox(height: 24),
      // 抽选人数：MD3 图标按钮。窄卡片下标签与步进器分行，避免 Row 溢出。
      LayoutBuilder(
        builder: (context, constraints) {
          final label = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.numbers, color: colorScheme.primary, size: 18),
              const SizedBox(width: 8),
              Text('抽选人数：', style: theme.textTheme.bodyMedium),
            ],
          );
          final stepper = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: _pickCount <= 1 || !canDraw
                    ? null
                    : () => setState(() => _pickCount -= 1),
                tooltip: '减少抽选人数',
                style: stepperButtonStyle,
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '$_pickCount',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                onPressed: !canDraw
                    ? null
                    : () => setState(() => _pickCount += 1),
                tooltip: '增加抽选人数',
                style: stepperButtonStyle,
                icon: const Icon(Icons.add),
              ),
            ],
          );
          if (constraints.maxWidth < 240) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label,
                const SizedBox(height: 8),
                stepper,
              ],
            );
          }
          return Row(
            children: [
              label,
              const Spacer(),
              stepper,
            ],
          );
        },
      ),
    ];

    // 抽选按钮：一次读库、一次提交完成连续抽选。
    final drawButton = SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        icon: appState.isDrawing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.casino_outlined),
        onPressed: canDraw ? () => appState.drawStudents(_pickCount) : null,
        label: const Text('抽选'),
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
        child: isWide
            // 双栏布局下卡片有确定高度：上方内容可滚动，按钮固定在卡片底部。
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: controls,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  drawButton,
                ],
              )
            // 单栏布局高度由内容决定，按钮紧随选项之后。
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...controls,
                  const SizedBox(height: 24),
                  drawButton,
                ],
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
          trailing: DropdownMenu<int>(
            initialSelection: appState.themeMode,
            selectOnly: true,
            width: 150,
            dropdownMenuEntries: const [
              DropdownMenuEntry(value: 0, label: "跟随系统"),
              DropdownMenuEntry(value: 1, label: "亮色"),
              DropdownMenuEntry(value: 2, label: "暗色"),
            ],
            onSelected: (value) {
              if (value != null) appState.setThemeMode(value);
            },
          ),
        ),
        ListTile(
          leading: Icon(Icons.repeat),
          title: Text("允许重复抽取"),
          subtitle: Text("关闭后，本轮符合筛选条件的学生抽完即自动开始新一轮"),
          trailing: Switch(
            value: appState.allowRepeat,
            onChanged: appState.isReady ? appState.setAllowRepeat : null,
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
  late Future<List<Contributor>> _contributorsFuture;

  static const _contributionLabels = {
    'code': '代码',
    'design': '设计',
    'maintenance': '维护',
    'bug': '缺陷报告',
    'doc': '文档',
    'review': '审查',
    'test': '测试',
    'ideas': '创意',
  };

  @override
  void initState() {
    super.initState();
    // 只在初始化时加载一次，避免每次重建都重新发起请求。
    _contributorsFuture = loadContributors();
  }

  String _formatContributions(List<String> contributions) {
    return contributions.map((c) => _contributionLabels[c] ?? c).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    final header = Column(
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
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                'NamePicker',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SvgPicture.asset(
                'assets/lite.svg',
                height: (theme.textTheme.headlineSmall?.fontSize ?? 24) / 1.414,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          "$version · $codename",
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    final devCard = Card(
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
                    child: Image.asset(
                      'assets/avatars/lhgser.jpg',
                      width: 48,
                      height: 48,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '灵魂歌手er',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '开发者',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '「这次能让我玩得开心点吗？」',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  const url = 'https://github.com/NamePickerOrg/NamePicker';
                  var opened = false;
                  try {
                    opened = await launchUrl(Uri.parse(url));
                  } catch (_) {
                    opened = false;
                  }
                  if (!opened) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('无法打开链接')),
                    );
                  }
                },
                icon: Icon(Icons.open_in_new),
                label: Text('GitHub'),
              ),
            ),
          ],
        ),
      ),
    );

    final copyright = Text(
      "© 2025-2026 NamePickerOrg",
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
    );

    final contributorsCard = FutureBuilder<List<Contributor>>(
      future: _contributorsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: colorScheme.outlineVariant, width: 1),
            ),
            color: colorScheme.surface,
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Text('无法加载贡献者列表'),
            ),
          );
        }

        final all = snapshot.data!;
        final hasMore = all.length > 3;
        final display = _contributorsExpanded ? all : all.take(3).toList();

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
                Text(
                  '贡献者',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                for (int i = 0; i < display.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: colorScheme.primaryContainer,
                        child: ClipOval(
                          child: Image.network(
                            display[i].avatarUrl,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Icon(
                              Icons.person,
                              size: 20,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              display[i].name,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatContributions(display[i].contributions),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                if (hasMore)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(
                        () => _contributorsExpanded = !_contributorsExpanded,
                      ),
                      child: Text(
                        _contributorsExpanded ? '收起' : '展开全部 (${all.length})',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 600) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          const SizedBox(height: 24),
                          devCard,
                          const SizedBox(height: 24),
                          copyright,
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: contributorsCard),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 24),
                  devCard,
                  const SizedBox(height: 12),
                  contributorsCard,
                  const SizedBox(height: 24),
                  copyright,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// 成为英雄吧，救世主。
