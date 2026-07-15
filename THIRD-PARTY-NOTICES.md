# Third-Party Notices

SingPilot 自身的脚本以 MIT 授权（见 [LICENSE](LICENSE)）。
本仓库还**再分发**了以下第三方成果，它们各自的授权条款如下。

---

## YACD — Yet Another Clash Dashboard (`ui/`)

`ui/` 目录是 YACD 面板的预编译产物，用于 sing-box 的 Clash API 面板。

- 上游：<https://github.com/haishanh/yacd>
- 本仓库内的构建来自 MetaCubeX 的分支：<https://github.com/MetaCubeX/Yacd-meta>
- 授权：**MIT License** — Copyright (c) Haishan

```
MIT License

Copyright (c) Haishan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### YACD 打包内的字体资产（`ui/assets/`）

| 文件 | 来源 | 授权 |
|---|---|---|
| `Twemoji_Mozilla-*.ttf`、`ui/Twemoji_Mozilla.ttf` | [Twemoji](https://github.com/twitter/twemoji)（Mozilla 构建版） | 图形部分 **CC-BY 4.0**，代码部分 MIT。需署名 Twitter, Inc. 及其他贡献者 |
| `inter-latin-*.woff/woff2` | [Inter](https://github.com/rsms/inter) | **SIL Open Font License 1.1** |
| `roboto-mono-latin-*.woff/woff2` | [Roboto Mono](https://fonts.google.com/specimen/Roboto+Mono) | **Apache License 2.0** |

---

## sing-box

**未包含在本仓库中**，需使用者自行从官方下载（或用 `[14]` 拉取）。

- 上游：<https://github.com/SagerNet/sing-box>
- 授权：**GPL-3.0-or-later**

SingPilot 只是以外部进程方式调用 `sing-box.exe`（`sing-box run -c config.json`）
并访问其 Clash HTTP API，不链接、不修改、不分发其代码，因此不构成 GPL 意义上的衍生作品。

---

## 图标

`sing-box.ico` 用于快捷方式图标。若该图标源自 sing-box 项目的官方标识，
其著作权与商标权归 SagerNet 及其贡献者所有，本项目仅作非商业性引用。
如权利人认为不妥，请提 issue，我们会立即替换为自制图标。
