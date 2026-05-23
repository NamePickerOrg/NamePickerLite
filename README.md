<div align="center">
<img src="namepicker/assets/NamePicker-64rad.png" alt="icon" width="18%">
<h1>NamePicker</h1>
<h3>一款简洁的点名软件</h3>
</div>

[QQ群（群号2153027375）](https://qm.qq.com/q/fTjhKuAlCU)

[NamePicker文档](https://namepicker-docs.netlify.app/)

> [!note]
>
> NamePicker 基于 GNU GPLv3 协议开源
>
> GNU GPLv3 具有 Copyleft 特性，也就是说，您可以修改 NamePicker 的源代码，但是**必须将修改版本同样以 GNU GPLv3 协议开源**

> [!caution]
>
> NamePicker 是一款完全开源且免费的软件，官方也没有提供任何付费服务
>
> 如果您需要在某处售卖 NamePicker，或者需要提供有关 NamePicker 的付费服务，请参照[该指南](https://www.baidu.com/s?wd=家里人全死光了怎么办)

## 功能清单/大饼

> 概率内定过于缺德，并且实现难度相当高，不会考虑

1. [x] 基础的点名功能
2. [x] 人性化（大嘘）的配置修改界面
3. [x] 从外部读取名单
4. [x] 特殊点名规则（性别/学号单双号筛选）
5. [x] 多名单支持
6. [x] 同时抽选多个
7. [x] Material 3 主题（亮色/暗色/跟随系统）
8. [x] 桌面端自定义标题栏
9. [ ] 播报抽选结果
10. [x] 与 ClassIsland/Class Widgets 联动（联动插件均已上架对应软件的插件商城）
11. [ ] 手机遥控抽选
12. [x] 改用 Flutter 跨平台框架

## 支持的平台
1. [x] Windows 10+
2. [x] Linux（国产化系统）
3. [x] macOS
4. [x] Android
5. [x] iOS
6. [x] Web

## 运行指南

### 环境要求

- [Flutter SDK](https://docs.flutter.dev/get-started/install) >= 3.8.1
- Dart SDK >= 3.8.1

### 运行指南（源码）

```bash
cd namepicker
flutter pub get
flutter run
```

### 打包可执行文件指南

```bash
cd namepicker

# Windows
flutter build windows

# Linux
flutter build linux

# macOS
flutter build macos

# Android
flutter build apk

# iOS
flutter build ios

# Web
flutter build web
```

构建产物位于 `namepicker/build/` 目录下。

## FAQ
### Q: 怎么配置名单

A: 参见[文档](https://namepicker-docs.netlify.app/usage/names.html)

### Q: 杀毒软件认为这是病毒软件

A: 将该软件添加至杀毒软件的白名单/信任区中，本软件保证不含病毒，您可以亲自审查代码，如果还是觉得不放心可以不使用

## 鸣谢 ✨

感谢以下贡献者（[emoji key](https://allcontributors.org/docs/en/emoji-key)）：

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/LHGS-github"><img src="https://avatars.githubusercontent.com/u/92249708?v=4?s=100" width="100px;" alt="灵魂歌手er"/><br /><sub><b>灵魂歌手er</b></sub></a><br /><a href="#code-LHGS-github" title="Code">💻</a> <a href="#maintenance-LHGS-github" title="Maintenance">🚧</a> <a href="#design-LHGS-github" title="Design">🎨</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/unDefFtr"><img src="https://avatars.githubusercontent.com/u/83688818?v=4?s=100" width="100px;" alt="谭麒峰"/><br /><sub><b>谭麒峰</b></sub></a><br /><a href="#maintenance-unDefFtr" title="Maintenance">🚧</a> <a href="#design-unDefFtr" title="Design">🎨</a> <a href="#code-unDefFtr" title="Code">💻</a> <a href="#bug-unDefFtr" title="Bug reports">🐛</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
