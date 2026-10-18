import 'main.dart';
import 'package:flutter/material.dart';
import 'student.dart';
import 'student_db.dart';
import 'csv_transfer.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'qr_transfer.dart';

/// 学生已经不在数据库中（例如在另一个窗口被删除）。
class StudentMissingException implements Exception {
  final String message;
  const StudentMissingException(this.message);

  @override
  String toString() => message;
}

class StudentEditorPage extends StatefulWidget {
  const StudentEditorPage({Key? key}) : super(key: key);

  @override
  State<StudentEditorPage> createState() => _StudentEditorPageState();
}

class _StudentEditorPageState extends State<StudentEditorPage> {
  List<Student> students = [];
  bool loading = true;
  String? _loadError;
  int? _loadedListId;
  int _loadedRevision = -1;
  int _loadRequest = 0;
  bool _transferBusy = false;

  MyAppState get _appState => Provider.of<MyAppState>(context, listen: false);
  List<ListGroup> get lists => _appState.lists;
  int? get currentListId => _appState.currentListId;

  /// 页面缓存与当前名单完全一致时才允许导出/导入，避免导出上一份名单。
  bool get _canTransfer =>
      _loadedListId == currentListId &&
      _loadedRevision == _appState.rosterRevision &&
      !loading &&
      _loadError == null &&
      !_transferBusy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 注册对全局名单状态的依赖：名单切换与名单内容变化都从这里同步。
    final appState = Provider.of<MyAppState>(context);
    if (!appState.isReady) return;
    if (appState.currentListId != _loadedListId ||
        appState.rosterRevision != _loadedRevision) {
      _loadStudents();
    }
  }

  Future<void> _loadStudents() async {
    final appState = _appState;
    final listId = appState.currentListId;
    final revision = appState.rosterRevision;
    final request = ++_loadRequest;
    _loadedListId = listId;
    _loadedRevision = revision;
    if (!mounted) return;
    setState(() {
      loading = true;
      _loadError = null;
      students = [];
    });
    if (listId == null) {
      setState(() => loading = false);
      return;
    }
    try {
      final result = await appState.readStudents(listId);
      // 只接受仍然是最新请求、且名单与内容版本都没有变化的返回。
      if (!mounted || request != _loadRequest) return;
      if (appState.currentListId != listId ||
          appState.rosterRevision != revision) {
        return;
      }
      setState(() {
        students = result;
        loading = false;
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        loading = false;
        _loadError = '名单加载失败';
      });
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            // 破坏性操作的默认焦点放在取消上。
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  )
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _createList() async {
    final appState = _appState;
    await showDialog<void>(
      context: context,
      builder: (_) => ListNameDialog(
        title: '新建名单',
        initialName: '',
        onSave: (name) async {
          await appState.createList(name);
        },
      ),
    );
  }

  Future<void> _renameList(ListGroup list) async {
    final appState = _appState;
    await showDialog<void>(
      context: context,
      builder: (_) => ListNameDialog(
        title: '重命名单',
        initialName: list.name,
        onSave: (name) => appState.renameList(ListGroup(id: list.id, name: name)),
      ),
    );
  }

  Future<void> _deleteList(ListGroup list) async {
    final appState = _appState;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirm(
      title: '删除名单',
      message: '确定删除名单「${list.name}」吗？该名单内所有学生也将删除，且无法恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true) return;
    try {
      final deleted = await appState.deleteList(list.id!);
      if (!deleted) {
        messenger.showSnackBar(const SnackBar(content: Text('至少保留一个名单')));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('删除名单失败，请重试')));
    }
  }

  Future<void> _addOrEditStudent([Student? student]) async {
    final appState = _appState;
    final targetListId = appState.currentListId;
    if (targetListId == null) return;
    final originalId = student?.id;
    await showDialog<void>(
      context: context,
      builder: (_) => StudentDialog(
        student: student,
        onSave: (edited) async {
          if (originalId == null) {
            await StudentDatabase.instance.create(edited, targetListId);
          } else {
            final affected = await StudentDatabase.instance.update(edited);
            if (affected == 0) {
              throw const StudentMissingException('学生已不存在');
            }
          }
          appState.studentsChanged(targetListId);
        },
      ),
    );
  }

  Future<void> _confirmDeleteStudent(Student student) async {
    final targetId = student.id;
    if (targetId == null) return;
    final targetListId = _loadedListId;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirm(
      title: '删除学生',
      message: '确定删除「${student.name}」吗？此操作无法撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true) return;
    try {
      final affected = await StudentDatabase.instance.delete(targetId);
      if (affected == 0) {
        messenger.showSnackBar(const SnackBar(content: Text('学生已不存在')));
      }
      if (targetListId != null) _appState.studentsChanged(targetListId);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('删除学生失败，请重试')));
    }
  }

  Future<void> _exportCsvDialog() async {
    if (!_canTransfer) return;
    final csv = studentsToCsv(students);
    final messenger = ScaffoldMessenger.of(context);
    if (kIsWeb) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Web 端暂不支持导出')),
      );
      return;
    }
    // 分享位置要在 await 之前从当前页面的 RenderBox 取。
    final renderBox = context.findRenderObject() as RenderBox?;
    final sharePositionOrigin = renderBox == null
        ? null
        : renderBox.localToGlobal(Offset.zero) & renderBox.size;

    setState(() => _transferBusy = true);
    try {
      final now = DateTime.now();
      final timestamp =
          "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}";
      final filename = "namepicker-export-$timestamp.csv";

      if (Platform.isAndroid) {
        // 通过系统保存器写文件，不直接写公共目录、不申请存储权限。
        final savedPath = await FilePicker.platform.saveFile(
          dialogTitle: '导出名单为 CSV',
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: ['csv'],
          bytes: Uint8List.fromList(utf8.encode(csv)),
        );
        if (savedPath == null) return;
        messenger.showSnackBar(const SnackBar(content: Text('导出完成')));
      } else if (Platform.isIOS) {
        final directory = await getTemporaryDirectory();
        final file = File('${directory.path}/$filename');
        await file.writeAsString(csv, flush: true);

        // ignore: deprecated_member_use
        final result = await Share.shareXFiles(
          [XFile(file.path)],
          sharePositionOrigin: sharePositionOrigin,
        );
        switch (result.status) {
          case ShareResultStatus.dismissed:
            // 用户取消分享，不提示成功。
            break;
          case ShareResultStatus.success:
            messenger.showSnackBar(
              const SnackBar(content: Text('已完成分享操作')),
            );
          case ShareResultStatus.unavailable:
            messenger.showSnackBar(
              const SnackBar(content: Text('分享面板已打开，无法确认结果')),
            );
        }
      } else {
        final outputPath = await FilePicker.platform.saveFile(
          dialogTitle: '导出名单为 CSV',
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: ['csv'],
        );
        if (outputPath == null) return;
        await File(outputPath).writeAsString(csv, flush: true);
        messenger.showSnackBar(
          SnackBar(content: Text('导出完成: $outputPath')),
        );
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
    } finally {
      if (mounted) setState(() => _transferBusy = false);
    }
  }

  Future<void> _qrExport() async {
    if (!_canTransfer) return;
    final csv = studentsToCsv(students);
    await showQrExportDialog(context, csv);
  }

  Future<void> _qrImport() async {
    if (!_canTransfer) return;
    final targetListId = _loadedListId;
    final targetListName = _listName(targetListId);
    if (targetListId == null) return;

    final first = await showQrScanner(context);
    if (first == null) return;

    final QrChunkRef? firstRef;
    try {
      firstRef = parseQrChunk(first);
    } on FormatException catch (e) {
      if (mounted) await _showInfo('格式错误', e.message);
      return;
    }
    if (firstRef == null) {
      await _processQrPayload(first, targetListId, targetListName);
      return;
    }

    // 先校验分片信息，再分配数组。
    final total = firstRef.total;
    final chunks = List<String>.filled(total, '');
    chunks[firstRef.index - 1] = firstRef.payload;

    int nextExpected() {
      for (var i = 0; i < total; i++) {
        if (chunks[i].isEmpty) return i;
      }
      return -1;
    }

    while (true) {
      final expected = nextExpected();
      if (expected < 0) break;
      if (!mounted) return;

      final collected = chunks.where((c) => c.isNotEmpty).length;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('已扫描 $collected/$total'),
          content: Text('请切换到第 ${expected + 1} 张二维码，然后点击继续。'),
          actions: [
            TextButton(
              child: const Text('取消'),
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            FilledButton(
              child: const Text('继续'),
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (proceed != true) return;

      // 持续扫描，直到拿到当前需要的分片。
      while (true) {
        if (!mounted) return;
        final next = await showQrScanner(
          context,
          title: 'QR 码导入 (${expected + 1}/$total)',
        );
        if (next == null) return;

        final QrChunkRef? ref;
        try {
          ref = parseQrChunk(next);
        } on FormatException catch (e) {
          if (mounted) await _showInfo('格式错误', e.message);
          continue;
        }
        if (ref == null || ref.total != total) {
          if (mounted) {
            await _showInfo(
              '格式错误',
              '扫描到无效的分段二维码，请扫描第 ${expected + 1} 张。',
            );
          }
          continue;
        }
        if (ref.index != expected + 1) {
          final target = chunks[ref.index - 1].isNotEmpty ? '已扫描过' : '不是当前需要的';
          if (mounted) {
            await _showInfo(
              '扫描顺序错误',
              '这张是第 ${ref.index} 张（$target）。\n请扫描第 ${expected + 1} 张二维码。',
            );
          }
          continue;
        }

        chunks[expected] = ref.payload;
        break;
      }
    }

    await _processQrPayload(chunks.join(), targetListId, targetListName);
  }

  Future<void> _showInfo(String title, String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            child: const Text('确定'),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }

  String _listName(int? listId) {
    for (final list in _appState.lists) {
      if (list.id == listId) return list.name;
    }
    return '';
  }

  Future<void> _processQrPayload(
    String raw,
    int targetListId,
    String targetListName,
  ) async {
    String csv;
    try {
      csv = decodeQrPayload(raw);
    } catch (e) {
      if (mounted) {
        _showInfo('解码失败', '无法解析二维码内容，请确认二维码来源正确。\n\n$e');
      }
      return;
    }

    await _runImport(csv, targetListId, targetListName);
  }

  Future<void> _runImport(
    String csv,
    int targetListId,
    String targetListName,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _transferBusy = true);
    String? error;
    var imported = 0;
    try {
      imported = await _importCsv(csv, targetListId);
    } catch (e) {
      error = e is FormatException ? e.message : '导入失败，请重试';
    } finally {
      if (mounted) setState(() => _transferBusy = false);
    }
    if (!mounted) return;
    if (error != null) {
      await _showInfo('导入失败', error);
      return;
    }
    _appState.studentsChanged(targetListId);
    messenger.showSnackBar(
      SnackBar(content: Text('已导入 $imported 名学生到「$targetListName」')),
    );
  }

  Future<void> _importCsvDialog() async {
    if (!_canTransfer) return;
    final targetListId = _loadedListId;
    final targetListName = _listName(targetListId);
    if (targetListId == null) return;

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        dialogTitle: "选择早期 NamePicker 版本的名单文件",
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件读取失败')),
        );
      }
      return;
    }
    if (result == null) return;

    final file = result.files.single;
    String content;
    try {
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!, allowMalformed: false);
      } else if (file.path != null) {
        content = utf8.decode(
          await File(file.path!).readAsBytes(),
          allowMalformed: false,
        );
      } else {
        throw const FormatException('无法读取所选文件');
      }
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('仅支持 UTF-8 编码的 CSV')),
        );
      }
      return;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件读取失败')),
        );
      }
      return;
    }

    await _runImport(content, targetListId, targetListName);
  }

  /// 先把整份 CSV 解析完，再一次性写入目标名单；返回写入条数。
  Future<int> _importCsv(String csvText, int targetListId) async {
    final parsed = studentsFromCsv(csvText);
    return StudentDatabase.instance.createMany(parsed, targetListId);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('名单编辑器'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: PopupMenuButton<int>(
              tooltip: '选择/管理名单',
              initialValue: currentListId,
              onSelected: (id) {
                // “新建名单”使用 -1 作为菜单动作，不能当作名单 ID 处理。
                if (id >= 0) _appState.setCurrentListId(id);
              },
              itemBuilder: (context) => [
                for (final l in lists)
                  PopupMenuItem<int>(
                    value: l.id,
                    child: Row(
                      children: [
                        Icon(
                          l.id == currentListId
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: l.id == currentListId
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey,
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Expanded(child: Text(l.name)),
                        IconButton(
                          icon: Icon(Icons.edit, size: 16),
                          tooltip: '重命名',
                          onPressed: () async {
                            Navigator.pop(context); // 关闭菜单
                            if (!mounted) return;
                            await _renameList(l);
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.delete, size: 16),
                          tooltip: '删除',
                          onPressed: () async {
                            Navigator.pop(context); // 关闭菜单
                            if (!mounted) return;
                            await _deleteList(l);
                          },
                        ),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem<int>(
                  value: -1,
                  enabled: true,
                  child: Row(
                    children: [
                      Icon(Icons.add, size: 18),
                      SizedBox(width: 8),
                      Text('新建名单'),
                    ],
                  ),
                  onTap: () {
                    // onSelected 仍会收到 -1，已在上面忽略。
                    _createList();
                  },
                ),
              ],
              child: Row(
                children: [
                  Icon(
                    Icons.list_alt,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  SizedBox(width: 6),
                  Text(
                    lists.isEmpty
                        ? '无名单'
                        : (lists
                              .firstWhere(
                                (l) => l.id == currentListId,
                                orElse: () => lists.first,
                              )
                              .name),
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Container(
        color: colorScheme.surfaceContainer,
        child: loading
            ? Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_loadError!),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _loadStudents,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: students.length,
                    itemBuilder: (context, index) {
                      final s = students[index];
                      return ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        title: Text(s.name),
                        subtitle:
                            Text('学号: ${s.studentId} | 性别: ${s.gender}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.edit),
                              onPressed: () => _addOrEditStudent(s),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.delete),
                              onPressed: () => _confirmDeleteStudent(s),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final selected = await showModalBottomSheet<String>(
            context: context,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(Icons.add),
                    title: Text('添加学生'),
                    onTap: () => Navigator.of(ctx).pop('add'),
                  ),
                  ListTile(
                    leading: Icon(Icons.upload_file),
                    title: Text('导入名单'),
                    onTap: () => Navigator.of(ctx).pop('import'),
                  ),
                  ListTile(
                    leading: Icon(Icons.download),
                    title: Text('导出名单'),
                    onTap: () => Navigator.of(ctx).pop('export'),
                  ),
                  ListTile(
                    leading: Icon(Icons.qr_code_scanner),
                    title: Text('QR 码导入'),
                    onTap: () => Navigator.of(ctx).pop('qr_import'),
                  ),
                  ListTile(
                    leading: Icon(Icons.qr_code_2),
                    title: Text('QR 码导出'),
                    onTap: () => Navigator.of(ctx).pop('qr_export'),
                  ),
                ],
              ),
            ),
          );
          if (!mounted) return;
          if (selected == 'add') {
            _addOrEditStudent();
          } else if (selected == 'import') {
            _importCsvDialog();
          } else if (selected == 'export') {
            _exportCsvDialog();
          } else if (selected == 'qr_import') {
            _qrImport();
          } else if (selected == 'qr_export') {
            _qrExport();
          }
        },
        child: Icon(Icons.add),
        tooltip: '操作',
      ),
    );
  }
}

/// 新建与重命名共用的名单名对话框，负责输入校验与保存状态。
class ListNameDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final Future<void> Function(String name) onSave;

  const ListNameDialog({
    super.key,
    required this.title,
    required this.initialName,
    required this.onSave,
  });

  @override
  State<ListNameDialog> createState() => _ListNameDialogState();
}

class _ListNameDialogState extends State<ListNameDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _controller.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(name);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.title),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _controller,
                autofocus: true,
                enabled: !_saving,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: '名单名'),
                onFieldSubmitted: (_) => _submit(),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? '请输入名单名' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class StudentDialog extends StatefulWidget {
  final Student? student;
  final Future<void> Function(Student student) onSave;

  const StudentDialog({super.key, this.student, required this.onSave});

  @override
  State<StudentDialog> createState() => _StudentDialogState();
}

class _StudentDialogState extends State<StudentDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _idController;
  final _formKey = GlobalKey<FormState>();
  String _gender = '男';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.student?.name ?? '');
    _idController = TextEditingController(
      text: widget.student?.studentId ?? '',
    );
    _gender = widget.student?.gender ?? '男';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final student = Student(
      id: widget.student?.id,
      name: _nameController.text.trim(),
      gender: _gender,
      studentId: _idController.text.trim(),
      listId: widget.student?.listId,
    );
    try {
      await widget.onSave(student);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is StudentMissingException
            ? error.message
            : '保存失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.student == null ? '添加学生' : '编辑学生'),
        content: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  enabled: !_saving,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: '姓名'),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入姓名' : null,
                ),
                TextFormField(
                  controller: _idController,
                  enabled: !_saving,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(labelText: '学号'),
                  onFieldSubmitted: (_) => _submit(),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入学号' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('student-gender-$_gender'),
                  initialValue: _gender,
                  decoration: const InputDecoration(labelText: '性别'),
                  items: const [
                    DropdownMenuItem(value: '男', child: Text('男')),
                    DropdownMenuItem(value: '女', child: Text('女')),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) setState(() => _gender = value);
                        },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}
