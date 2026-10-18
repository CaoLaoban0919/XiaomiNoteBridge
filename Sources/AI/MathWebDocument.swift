import Foundation

/// 编辑器、对话和导出共用的离线数学文档；不授予 WebKit 文件目录读取权限。
enum MathWebDocument {
    private struct Assets {
        let css: String
        let javascript: String
    }

    private static let assets: Result<Assets, Error> = Result {
        let root: URL
        if let path = ProcessInfo.processInfo.environment["MINOTE_RESOURCE_PATH"], !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else if let resourceURL = resourceBundle.resourceURL {
            root = resourceURL
        } else {
            throw NSError(domain: "MiNoteMath", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到离线 KaTeX 资源目录"])
        }
        let directory = root.appendingPathComponent("katex", isDirectory: true)
        var css = try String(contentsOf: directory.appendingPathComponent("katex.min.css"), encoding: .utf8)
        let sources = try NSRegularExpression(pattern: #"src:[^;]*url\([^)]*\.woff2\)[^;]*;"#)
        let fontURL = try NSRegularExpression(pattern: #"url\([\"']?([^\)\"']+\.woff2)[\"']?\)"#)
        for match in sources.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            guard let range = Range(match.range, in: css) else { continue }
            let source = String(css[range])
            guard let font = fontURL.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let pathRange = Range(font.range(at: 1), in: source) else { continue }
            let data = try Data(contentsOf: directory.appendingPathComponent(String(source[pathRange])))
            css.replaceSubrange(range, with: "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\");")
        }
        guard !css.contains("url(fonts/") else {
            throw NSError(domain: "MiNoteMath", code: 2, userInfo: [NSLocalizedDescriptionKey: "KaTeX 字体未完整内联"])
        }
        return Assets(css: css, javascript: try String(contentsOf: directory.appendingPathComponent("katex.min.js"), encoding: .utf8))
    }

    // Swift Package 的资源位于独立 .bundle；Xcode app 和 build.sh 则放在主 Bundle。
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    static func head() -> String {
        var library: String
        switch assets {
        case .success(let assets): library = assets.javascript
        case .failure(let error):
            let value = (try? JSONSerialization.data(withJSONObject: [error.localizedDescription])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"离线数学资源加载失败\"]"
            library = "window.__mathAssetError = \(value)[0];"
        }
        library += ";\n" + SurfaceChart.script
        return "<style>\(css)</style><script>\(library.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive))</script><script>\(script)</script>"
    }

    static var css: String {
        let library = (try? assets.get().css) ?? ""
        return library + #"""
        .mn-math { color: inherit; white-space: nowrap; }
        .mn-math:not(.mn-math-display) { display: inline-block; max-width: 100%; vertical-align: baseline; }
        .mn-math-display { display: block; max-width: 100%; overflow-x: auto; overflow-y: hidden; white-space: nowrap; padding: 3px 0; margin: 0.6em 0; }
        .mn-math > .katex, .mn-math > .katex-display { color: inherit; white-space: nowrap; }
        .mn-math > .katex-display { margin: 0; }
        .mn-math.mn-math-error { white-space: pre-wrap; overflow-wrap: anywhere; }
        .mn-math .mn-math-error-button { font: inherit; font-size: 0.8em; color: inherit; background: transparent; border: 1px solid currentColor; border-radius: 3px; margin-left: 0.5em; padding: 0 0.3em; cursor: help; }
        """#
    }

    static var script: String { #"""
    (function () {
      'use strict';
      if (window.MiNoteMath) return;
      window.__mathReady = false;
      window.__mathSettled = false;
      window.__mathErrors = [];
      const reports = new WeakMap();
      let queue = Promise.resolve();
      const encode = text => btoa(Array.from(new TextEncoder().encode(text), b => String.fromCharCode(b)).join(''));
      const decode = text => new TextDecoder('utf-8', {fatal: true}).decode(Uint8Array.from(atob(text), c => c.charCodeAt(0)));
      const sourceOf = node => {
        const source = node.getAttribute('data-mn-source') || node.getAttribute('data-math-source');
        if (source !== null) return decode(source);
        if (!node.querySelector('.katex') && node.tagName !== 'IMG') return node.textContent;
        const latex = decode(node.getAttribute('data-latex'));
        return node.getAttribute('data-display') === 'true' ? '\\[' + latex + '\\]' : '\\(' + latex + '\\)';
      };
      const makeNode = (latex, display, source) => {
        const node = document.createElement('span');
        node.className = 'mn-math' + (display ? ' mn-math-display' : '');
        node.setAttribute('data-latex', encode(latex));
        node.setAttribute('data-display', String(display));
        node.setAttribute('contenteditable', 'false');
        node.textContent = source;
        return node;
      };
      const all = (root, selector) => (root.matches && root.matches(selector) ? [root] : []).concat(Array.from(root.querySelectorAll(selector)));
      const escaped = (text, index) => {
        let slashes = 0;
        for (let p = index - 1; p >= 0 && text[p] === '\\'; p--) slashes++;
        return slashes % 2 === 1;
      };
      function migrate(root) {
        for (const old of all(root, '.katex')) {
          if (old.closest('[data-latex],code,pre,script,style')) continue;
          const annotation = old.querySelector('annotation[encoding="application/x-tex"]');
          if (!annotation) continue;
          const displayParent = old.parentElement && old.parentElement.classList.contains('katex-display') ? old.parentElement : null;
          const display = !!displayParent;
          const latex = annotation.textContent;
          (displayParent || old).replaceWith(makeNode(latex, display, display ? '\\[' + latex + '\\]' : '\\(' + latex + '\\)'));
        }
        for (const image of all(root, 'img[data-latex]')) {
          try { image.replaceWith(makeNode(decode(image.getAttribute('data-latex')), image.getAttribute('data-display') === 'true', sourceOf(image))); }
          catch (_) { /* 属性损坏的图片保留，不猜测图片内容。 */ }
        }
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const texts = [];
        while (walker.nextNode()) {
          const node = walker.currentNode;
          if (!node.parentElement.closest('[data-latex],.katex,code,pre,script,style,textarea,button')) texts.push(node);
        }
        const pairs = [['$$','$$',true], ['\\[','\\]',true], ['\\(','\\)',false], ['$','$',false]];
        for (const node of texts) {
          const text = node.nodeValue;
          let cursor = 0, last = 0, changed = false;
          const fragment = document.createDocumentFragment();
          while (cursor < text.length) {
            let match = null;
            if (!escaped(text, cursor)) {
              for (const pair of pairs) {
                if (!text.startsWith(pair[0], cursor)) continue;
                if (pair[0] === '$' && (text[cursor - 1] === '$' || text[cursor + 1] === '$')) continue;
                let end = text.indexOf(pair[1], cursor + pair[0].length);
                while (end >= 0 && (escaped(text, end) || (pair[0] === '$' && (text[end - 1] === '$' || text[end + 1] === '$')))) end = text.indexOf(pair[1], end + pair[1].length);
                if (end < 0) continue;
                const latex = text.slice(cursor + pair[0].length, end);
                if (!latex.trim() || (pair[0] === '$' && (/^\s|\s$|[\r\n]/.test(latex) || /[0-9]/.test(text[end + 1] || '')))) continue;
                match = {pair, end, latex};
                break;
              }
            }
            if (!match) { cursor++; continue; }
            fragment.append(document.createTextNode(text.slice(last, cursor)));
            const end = match.end + match.pair[1].length;
            fragment.append(makeNode(match.latex, match.pair[2], text.slice(cursor, end)));
            cursor = last = end;
            changed = true;
          }
          if (changed) {
            fragment.append(document.createTextNode(text.slice(last)));
            node.replaceWith(fragment);
          }
        }
      }
      function fail(node, error, latex, source) {
        const message = error && error.message ? error.message : String(error);
        node.textContent = source;
        node.classList.add('mn-math-error');
        node.removeAttribute('data-mn-rendered');
        node.setAttribute('data-mn-error', message);
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'mn-math-error-button';
        button.textContent = '公式错误';
        button.title = message;
        button.setAttribute('aria-label', '公式错误：' + message);
        button.setAttribute('contenteditable', 'false');
        button.addEventListener('click', () => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mathError;
          if (handler) handler.postMessage({latex, message});
        });
        node.append(button);
        const issue = {latex, display: node.getAttribute('data-display') === 'true', message};
        const key = latex + '\n' + message;
        if (reports.get(node) !== key) {
          reports.set(node, key);
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mathError;
          if (handler) handler.postMessage(issue);
          else console.error('MiNoteMath:', issue);
        }
      }
      async function render(root) {
        window.__mathReady = false;
        window.__mathSettled = false;
        migrate(root);
        if (window.MiNoteSurface) window.MiNoteSurface.start(root);
        for (const node of all(root, '[data-latex]')) {
          let latex = '', source = node.textContent;
          try {
            source = sourceOf(node);
            node.setAttribute('data-mn-source', encode(source));
            latex = decode(node.getAttribute('data-latex'));
            const display = node.getAttribute('data-display') === 'true';
            const key = node.getAttribute('data-latex') + ':' + display;
            if (node.getAttribute('data-mn-rendered') === key && node.querySelector('.katex')) continue;
            if (window.__mathAssetError) throw new Error(window.__mathAssetError);
            if (!window.katex) throw new Error('离线 KaTeX 未加载');
            node.classList.add('mn-math');
            node.classList.toggle('mn-math-display', display);
            node.setAttribute('contenteditable', 'false');
            katex.render(latex, node, {displayMode: display, throwOnError: true, strict: 'ignore', trust: false, output: 'htmlAndMathml', maxSize: 50, maxExpand: 1000});
            if (!node.querySelector('.katex')) throw new Error('公式渲染未生成内容');
            node.classList.remove('mn-math-error');
            node.removeAttribute('data-mn-error');
            node.setAttribute('data-mn-rendered', key);
          } catch (error) { fail(node, error, latex, source); }
        }
        await document.fonts.ready;
        window.__mathErrors = all(document.body, '[data-mn-error]').map(node => ({latex: (() => {try {return decode(node.getAttribute('data-latex'));} catch (_) {return '';}})(), display: node.getAttribute('data-display') === 'true', message: node.getAttribute('data-mn-error')}));
        if (window.__mathAssetError && !window.__mathErrors.length) window.__mathErrors.push({message: window.__mathAssetError});
        window.__mathSettled = true;
        window.__mathReady = window.__mathErrors.length === 0;
        if (!window.__mathReady) throw new Error(window.__mathErrors.map(error => error.message).join('\n'));
        return {count: all(root, '[data-latex]').length, errors: []};
      }
      function start(root = document.body) {
        const job = queue.then(() => render(root));
        queue = job.catch(() => {});
        return job;
      }
      function canonicalHTML() {
        const clone = document.body.cloneNode(true);
        for (const element of clone.querySelectorAll('script,style,link,meta,base,iframe,object,embed')) element.remove();
        migrate(clone);
        for (const node of all(clone, '[data-latex]')) {
          const source = sourceOf(node);
          node.textContent = source;
          node.classList.remove('mn-math-error');
          for (const attribute of Array.from(node.attributes)) if (attribute.name.startsWith('data-mn-')) node.removeAttribute(attribute.name);
        }
        return clone.innerHTML;
      }
      window.MiNoteMath = {start, canonicalHTML};
      const boot = () => start().catch(error => { console.error('MiNoteMath 渲染失败：', error.message); });
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, {once: true});
      else boot();
    })();
    """# }
}
