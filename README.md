# XiaomiNoteBridge

用于将 Apple 笔记与小米笔记进行同步的项目。可以把小米云上的笔记下载保存到 Apple 笔记中，并且进行修改。

## 安装

1. 下载 `MiNoteBridge-1.0.dmg`
2. 双击打开，把 **米记桥** 拖进 Applications
3. **首次打开会被 macOS 拦下**（本项目没有付费开发者证书，未做公证），任选一种方式：

   **方式一（推荐）**：在「应用程序」里**右键**点 米记桥 → 选择「打开」→ 弹窗里再点一次「打开」

   **方式二（终端）**：
   ```bash
   xattr -dr com.apple.quarantine /Applications/MiNoteBridge.app
   ```

   只需要做一次，之后正常双击即可。

> 为什么会有这个提示：macOS 对未公证的应用默认拦截。本项目使用临时签名（ad-hoc），功能完整，只是少了 Apple 的公证票据。

## 许可

本项目采用 **PolyForm Noncommercial License 1.0.0**（非商业许可）。

- **允许**：个人使用、学习研究、修改、分发（需附带本许可）
- **禁止**：任何商业用途——包括在商业产品/服务中使用、以营利为目的分发
- **商业授权**：如需商用，请先取得作者书面授权

完整条款见 [LICENSE](LICENSE)，或访问
<https://polyformproject.org/licenses/noncommercial/1.0.0>
