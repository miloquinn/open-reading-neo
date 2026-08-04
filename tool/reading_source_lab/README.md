# Reading Source Lab

这是一个独立、无第三方运行时依赖的阅读书源解析与兼容性审计项目。它不联网、不执行
书源脚本，也不会输出请求头、登录配置或 Cookie 的具体值；用途是把大批 JSON 书源转成
可重复验证的结构统计和 Open Reading 兼容矩阵。

## 能做什么

- 读取单个书源、书源数组、`sourceUrls` 清单和常见包装对象。
- 按 `bookSourceUrl` 去重，同时保留最后一条配置，符合更新书源时的新配置覆盖语义。
- 识别搜索、发现、详情、目录、正文能力，以及 JS、WebView、POST、XPath、JSONPath、
  CSS、正则、状态变量、登录、Cookie、加密和非文字内容依赖。
- 生成 JSON 或 Markdown 报告；报告只包含字段名、数量和来源名称，不泄露配置值。
- 同时报告核心阅读链结构覆盖率和扩展能力等级。核心覆盖要求文字类型、有效地址、搜索、
  目录和正文结构齐全；扩展能力另按 `supported`、`partial` 和 `unsupported` 分类。

## 使用

```bash
cd tool/reading_source_lab
PYTHONPATH=src python3 -m reading_source_lab.cli \
  --format markdown \
  --output report.md \
  /path/to/sources-a.json /path/to/sources-b.json
```

不安装也可以直接运行：

```bash
PYTHONPATH=tool/reading_source_lab/src \
python3 -m reading_source_lab.cli --format json /path/to/sources.json
```

测试：

```bash
PYTHONPATH=tool/reading_source_lab/src \
python3 -m unittest discover -s tool/reading_source_lab/tests
```

## 设计边界

审计结果表示“规则依赖是否被引擎覆盖”，不表示目标网站在线，也不表示验证码、登录、付费
或风控已经通过。完整可用性仍需在 Open Reading 中执行搜索→详情→目录→正文链路验证。

规则研究基于公开阅读书源执行实现的源码快照（下载日期 2026-08-04）。关键语义来源和
Open Reading 对照见 [docs/compatibility.md](docs/compatibility.md)。
