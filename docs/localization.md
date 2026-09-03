# Tactile 本地化与语言包

Tactile 使用可扩展的语言包。每种语言都是一个独立的 BCP-47 资源目录，应用启动时从主 Bundle 扫描并注册语言包；增加语言不需要在 Swift 中增加语言枚举或分支。

## 目录结构

```text
Tactile/Localization/
├── en.lproj/
│   ├── Localizable.strings
│   └── Localizable.stringsdict
└── zh-Hans.lproj/
    ├── Localizable.strings
    └── Localizable.stringsdict
```

每个发布语言包都应提供 `Localizable.strings`；只要英文基准包含复数键，各语言也必须提供键集合一致的 `Localizable.stringsdict`。每个语言包都必须在 `.strings` 中包含：

```text
"language.pack.display-name" = "该语言的自称";
```

例如英文包使用 `English`，简体中文包使用 `简体中文`。显示名本身不通过另一个语言包翻译，因为它用于语言选择器中标识该语言。

`en` 是唯一的键集合基准。所有发布语言包的普通键集合和 plural 键集合必须分别与 `en` 完全一致，不能有重复键或空值。运行时查找顺序是“当前语言包 → 英文包 → 调用方提供的默认值 → 键名”，因此单个翻译缺失不会让整个界面失效。

## 语言选择与系统语言

设置保存在 UserDefaults 的 `languageSelection` 中，格式固定为：

```text
system
pack:<identifier>
```

`system` 表示跟随系统，`pack:<identifier>` 表示显式使用某个语言包。这个选择独立于 Profile、SettingsSnapshot、导入导出的 Profile JSON 和 per-app baseline，不应写入这些持久化数据。应用只会把解析后的语言包 ID 临时放入 `FeedbackConfig`，供后台 hover caption 本地化；它不改变 Profile 或配置文件格式。显式选择的语言包被移除后会规范化为 `pack:en`。

跟随系统时只读取系统首选语言列表中的第一项。匹配顺序如下：

1. 完整规范化 BCP-47 ID 精确匹配。
2. 相同 language、script、region 的语言包。
3. 相同 language + script，但语言包不限定 region。
4. 相同 language + region，但语言包不限定 script。
5. 相同 language 的通用语言包。
6. 英文 `en` 回退。

匹配不会把不同书写系统混在一起。例如：

- `zh-Hans-CN`、`zh-CN`、`zh-SG` 可以解析到 `zh-Hans`。
- `zh-Hant`、`zh-TW`、`zh-HK`、`zh-MO` 不会解析到 `zh-Hans`，没有繁体包时显示英文。
- `en-US`、`en-GB` 可以解析到 `en`。
- `fr-FR` 可以解析到未来的通用 `fr`，但不能随意解析到 `fr-CA`。
- Unicode extension（例如 `-u-ca-gregory`）不改变基础语言、script 和 region 的匹配。

显式选择语言包后，系统 Locale 变化不会改变当前显示语言；只有选择 `system` 时，系统 Locale 变化才会重新解析语言包并刷新界面。

## 本地化键

键必须表达稳定的 UI 语义，不要把用户可见英文或中文正文硬编码在 Swift 中。当前命名空间为：

```text
language.*
window.*
menu.*
onboarding.*
settings.<pane>.*
feedback.category.*
feedback.pattern.*
waveform.*
dialog.*
format.*
a11y.*
error.*
```

所有应用文案都通过 `Localizer` 查找，包括 SwiftUI 的普通短文本，以保证逐键英文回退与手动选择的语言一致。已解析的文案使用 `Text(verbatim:)` 或接受动态 `String` 的控件构造器，避免二次本地化。格式化文案必须保留英文基准中每个参数的 printf 类型。位置标记可以调整显示顺序，例如 `%d %@` 可以翻译为 `%2$@ %1$d`，但不能改成 `%1$@ %2$d`；宽度和精度的星号参数同样参与类型检查。

复数文案使用 `.stringsdict`，不要在 Swift 中拼接 `pulse/pulses`、`line/lines` 等词。每个 plural 键的 `NSStringLocalizedFormatKey`、变量名、变量下的格式键/复数类别以及占位符签名都必须与英文基准兼容。

## 新增语言

1. 按 BCP-47 创建新的 `<identifier>.lproj`，例如 `fr.lproj` 或 `pt-BR.lproj`。
2. 在目录中添加 `Localizable.strings`；有复数文案时添加 `Localizable.stringsdict`。
3. 翻译英文基准中的全部键，并提供该语言自称的 `language.pack.display-name`。
4. 在 `Tactile.xcodeproj/project.pbxproj` 的 `knownRegions` 中加入对应的 Xcode region 元数据。文件系统同步的资源组会自动包含新的 `.lproj` 文件。
5. 运行校验器和无签名 Debug 构建。

不要修改 Swift 中的语言列表、语言分支、UserDefaults 格式或匹配算法。新增语言只应增加资源目录和 Xcode region 元数据。

## 验证

从仓库根目录运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift scripts/validate_localizations.swift
```

校验器会扫描所有 `.lproj`，检查 `.strings` 语法、重复键、空值、英文键集合、显示名、printf 占位符和 `.stringsdict` plural 结构，并直接编译生产 `LanguageIdentifierMatcher.swift` 运行固定的 BCP-47 匹配矩阵。发现问题时以非零状态退出。

完整的自动验证（包含以下 Debug 构建）可以一次运行：

```bash
bash scripts/test_localization.sh
```

该脚本还直接编译生产 Localizer，分别验证源码资源和 App 内资源的复数、参数重排、逐键回退与语言包发现；随后链接真实 Debug 模块，验证语言状态、系统通知、已删除语言包的规范化、Profile JSON、旧快捷键兼容性，以及悬浮标签刷新不触发额外触觉反馈。测试使用独立的临时 Bundle 和 UserDefaults suite，不启动反馈管线，也不修改用户现有设置。所有构建和测试产物都在 `/private/tmp`。

校验器自身的错误资源、Unicode 转义和格式参数测试可单独运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift scripts/validate_localizations.swift --self-test
```

无签名 Debug 构建使用 Xcode 26.6 和临时构建目录：

无签名构建仅用于自动验证。如果要长期使用本地 App 并在重新构建后尽量保留辅助功能权限，请使用 [稳定本地签名构建](local-signing.md)：`bash scripts/build_local_signed.sh`。它会使用本机已有证书，不修改上游发布团队设置。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Tactile.xcodeproj \
  -scheme Tactile \
  -configuration Debug \
  -sdk macosx \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/tactile-localization-build/DerivedData \
  -clonedSourcePackagesDirPath /private/tmp/tactile-localization-build/SourcePackages \
  -packageCachePath /private/tmp/tactile-localization-build/PackageCache \
  -disablePackageRepositoryCache \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

构建完成后应确认 App 资源中存在：

```text
Tactile.app/Contents/Resources/en.lproj
Tactile.app/Contents/Resources/zh-Hans.lproj
```

## 翻译范围与保留内容

语言包覆盖 Tactile 原生 macOS App 的菜单栏菜单、首次引导、设置页、Sheet、NSPanel、Accessibility 标签、动态错误和 hover caption。翻译切换应即时刷新当前窗口和菜单，不需要重启反馈管线。伴随的 Chrome 扩展自身界面不属于这个 App 语言包的运行时范围。

以下内容保持原样：品牌名 `Tactile`、`Coast`、`Chrome`、`Magic Trackpad`，URL、Bundle ID、应用名称、用户名称、用户 Profile 名、用户文件名、用户输入和外部应用控件标题。不要把这些值送入本地化键，也不要对它们进行二次本地化。

Sparkle 提供的更新窗口可能仍跟随系统语言。这是第三方窗口的已知限制，不应为了语言包修改 Sparkle。
