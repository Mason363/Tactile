# Tactile 本地化与语言包

[English](localization.md)

Tactile 使用可扩展的语言包。每种语言都是一个独立的 BCP-47 资源目录，应用启动时从主 Bundle 扫描并注册语言包；增加语言不需要在 Swift 中增加语言枚举、列表或分支。

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

每个发布语言包都应提供 `Localizable.strings`；由于英文基准包含复数键，各语言也必须提供复数键集合一致的 `Localizable.stringsdict`。每个语言包都必须在 `.strings` 中用该语言自称：

```text
"language.pack.display-name" = "简体中文";
```

显示名本身不通过另一个语言包翻译，因为语言选择器用它来标识该语言。

`en` 是唯一的键集合基准。所有发布语言包的普通键集合和复数键集合必须分别与 `en` 完全一致，不能有重复键或空值。运行时按键逐个回退：当前语言包 → 英文包 → 调用方提供的默认值 → 键名，因此单个翻译缺失不会让界面失效。

## 语言选择与系统语言

设置保存在 UserDefaults 的 `languageSelection` 中，格式固定为：

```text
system
pack:<identifier>
```

`system` 表示跟随系统，`pack:<identifier>` 表示显式使用某个语言包。这个选择是全局的，不属于 Profile、`SettingsSnapshot`、导出的 Profile JSON 或 per-app baseline。解析后的语言包 ID 只会临时放入 `FeedbackConfig`，供悬停标签本地化。显式选择的语言包被移除后会规范化为 `pack:en`。

跟随系统时，Tactile 会向 Foundation 提出 AppKit 为应用 Bundle 提出的同一个问题：用 `Bundle.preferredLocalizations(from:forPreferences:)` 匹配完整的系统首选语言列表。因此 Tactile 自己的文字与周围的系统面板、菜单和 Sparkle 窗口使用同一种语言。（macOS 在应用启动时确定其语言；若在 Tactile 运行期间更改语言列表，二者可能在 Tactile 重新启动前不同。）例如：

- `zh-Hans-CN`、`zh-CN`、`zh-SG` 使用 `zh-Hans`。
- `zh-Hant`、`zh-TW`、`zh-HK`、`zh-MO` 不会借用 `zh-Hans`：由列表中的下一种语言决定，最后回退到英文。
- `[fr-FR, zh-Hans-CN, en-US]` 在没有法语包时使用 `zh-Hans`。
- `en-US`、`en-GB` 使用 `en`。
- 地区回退同样由 macOS 决定：在当前 macOS 上，只有 `fr-CA` 一个法语包时，`fr-FR` 会使用它。
- 匹配时忽略 Unicode extension（例如 `-u-ca-gregory`）。

显式选择语言包后，系统变化不会改变当前显示语言；选择 `system` 时，系统 Locale 变化会重新解析语言包并刷新界面。

日期和时间按用户的地区设置显示（包括 24 小时制），不使用语言包的 Locale。

## 本地化键

键必须表达稳定的 UI 语义，不要把用户可见的英文或中文正文硬编码在 Swift 中。当前命名空间为：

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

所有应用文案都通过 `Localizer` 查找，包括 SwiftUI 的普通短文本，以保证逐键英文回退与应用内选择的语言一致。已解析的文案使用 `Text(verbatim:)` 或接受 `String` 的控件构造器，避免二次本地化。由枚举生成的键通过枚举的键属性获取（例如 `FeedbackCategory.nameLocalizationKey`）；状态测试会检查每个枚举值在每个语言包中都有对应的键。

格式化文案必须保留英文基准中每个参数的 printf 类型。位置标记可以调整顺序或重复使用参数：`%d %@` 可以翻译为 `%2$@ %1$d`，译文也可以两次输出 `%1$@`，但不能改成 `%1$@ %2$d`（类型交换）。宽度和精度的星号参数同样参与类型检查。

复数文案使用 `.stringsdict`，不要在 Swift 中拼接 `pulse/pulses`、`line/lines` 等词。每个复数键的 `NSStringLocalizedFormatKey`、变量名、格式键、复数类别以及占位符签名都必须与英文基准兼容。

## 新增语言

1. 按 BCP-47 创建新的 `<identifier>.lproj`，例如 `fr.lproj` 或 `pt-BR.lproj`。
2. 在目录中添加 `Localizable.strings`，并为复数键添加 `Localizable.stringsdict`。
3. 翻译英文基准中的全部键，并用该语言自称填写 `language.pack.display-name`。
4. 在 `Tactile.xcodeproj/project.pbxproj` 的 `knownRegions` 中加入对应的 Xcode region。文件系统同步的资源组会自动包含新的 `.lproj`。
5. 运行下方的校验器和完整测试脚本。

不要增加 Swift 语言列表、语言分支、UserDefaults 格式或匹配规则。新增语言只需要资源目录和 Xcode region 元数据。

## 验证

从仓库根目录运行：

```bash
swift scripts/validate_localizations.swift
```

校验器会扫描所有 `.lproj`，检查 `.strings` 语法、重复键、空值、英文键集合、显示名、printf 占位符和 `.stringsdict` 复数结构。它按 Foundation 在运行时的解码结果检查每个值，因此无法按原样显示的转义序列会被报告。它还会直接编译生产 `LanguageIdentifierMatcher.swift` 并运行固定的匹配矩阵。发现问题时以非零状态退出。

完整的自动验证（包含无签名 Debug 构建）可以一次运行：

```bash
bash scripts/test_localization.sh
```

该脚本直接编译生产 `Localizer`，分别针对源码资源和 App 内资源验证复数、参数重排、逐键回退与语言包发现；随后链接真实 Debug 模块，验证语言状态、系统通知、已删除语言包的规范化、Profile JSON、快捷键兼容性、枚举生成的键，以及悬停标签刷新不会触发额外触觉反馈。测试使用独立的临时 Bundle 和 UserDefaults suite，不启动反馈管线，也不修改用户现有设置。构建产物位于当前用户的临时目录（`$TMPDIR`）。

校验器自身的测试可单独运行：

```bash
swift scripts/validate_localizations.swift --self-test
```

无签名构建仅用于自动验证。如果要让本地构建在重新构建后保留辅助功能权限，请使用[稳定本地签名构建](local-signing.md)：`bash scripts/build_local_signed.sh`。

构建完成后，App 资源中应存在：

```text
Tactile.app/Contents/Resources/en.lproj
Tactile.app/Contents/Resources/zh-Hans.lproj
```

## 翻译范围与保留内容

语言包覆盖 Tactile 原生 macOS App 的菜单栏菜单、首次引导、设置页、Sheet、面板、辅助功能标签、动态错误和悬停标签。切换语言会即时刷新当前窗口和菜单，不需要重启反馈管线。伴随的 Chrome 扩展自身界面不属于这个运行时范围。

以下内容保持原样：品牌名 `Tactile`、`Coast`、`Chrome`、`Magic Trackpad`，URL、Bundle ID、应用名称、用户名称、Profile 名、文件名、用户输入和其他应用的控件标题。不要把这些值送入本地化键，也不要对它们进行二次本地化。

危险元素检测目前只识别英文标签，因此中文体验区中的按钮显示为“删除（Delete）”，演示仍会播放危险操作波形。

Sparkle 的更新窗口和其他系统界面遵循 macOS 自己的语言选择；选择“跟随系统”时，它与 Tactile 的语言一致，显式选择语言包时二者可能不同。
