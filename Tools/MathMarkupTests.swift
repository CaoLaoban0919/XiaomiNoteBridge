import Foundation

@main
enum MathMarkupTests {
    static var assertions = 0
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func latexNodes(_ html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"data-latex="([^"]*)""#)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html),
                  let data = Data(base64Encoded: String(html[range])) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    static func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    static func main() {
        let integral = #"""
        \int_1^{+\infty} \frac{1}{x^p}\,dx
        =\begin{cases}
          \frac{1}{p-1}, & p>1,\quad \text{收敛}\\

          +\infty, & p\leq 1,\quad \text{发散}
        \end{cases}
        """#
        let integralHTML = AITextToHTML.render("$$\n" + integral + "\n$$")
        check(latexNodes(integralHTML) == ["\n" + integral + "\n"], "p 积分及中文 cases 的 UTF8 源码完整保留")
        check(integralHTML.contains("class=\"mn-math mn-math-display\""), "块公式使用统一 display 类")
        check(integralHTML.contains("data-display=\"true\""), "块公式声明 display 模式")
        check(integralHTML.contains("contenteditable=\"false\""), "公式节点不可直接编辑")
        check(!integralHTML.contains("<br"), "公式内部物理换行不转换为 HTML 换行")
        check(integralHTML.contains("\n\n"), "公式内物理空行仍在 fallback 中")
        check(latexNodes(integralHTML).first?.contains(#"收敛}\\"#) == true, "显式 LaTeX 双反斜杠不改写")

        let fraction = #"\frac{a<b}{c>d} + \text{甲&乙}"#
        let fractionHTML = AITextToHTML.render("\\[" + fraction + "\\]")
        check(latexNodes(fractionHTML) == [fraction], "方括号分式保留未转义原文")
        check(fractionHTML.contains("&lt;b") && fractionHTML.contains("c&gt;d") && fractionHTML.contains("甲&amp;乙"), "公式 fallback 转义 HTML 特殊字符")
        check(!fractionHTML.contains("&amp;lt;"), "公式 fallback 不重复转义")

        let inline = AITextToHTML.render(#"**结论**：$x_1^2$，以及 \(\alpha + \beta\)。"#)
        check(latexNodes(inline) == ["x_1^2", #"\alpha + \beta"#], "两类行内定界符都解析")
        check(occurrences("data-display=\"false\"", in: inline) == 2, "两处行内公式均声明 inline 模式")
        check(inline.contains("<strong>结论</strong>"), "公式附近粗体不丢失")
        check(!inline.contains("<sup>") && !inline.contains("<sub>"), "不预转换公式上下标")

        let table = AITextToHTML.render(#"""
        | 表达式 | 说明 |
        | :--- | ---: |
        | $|x|$ | a\|b |
        | \(\left|y\right|\) | `c|d` |
        """#)
        check(table.contains("<table>"), "支持受限 Markdown 表格")
        check(occurrences("<th", in: table) == 3, "表头仍为两列加 thead")
        check(occurrences("<td", in: table) == 4, "数学和代码内部竖线不会拆列")
        check(latexNodes(table) == ["|x|", #"\left|y\right|"#], "表格数学完整保留")
        check(table.contains("a|b") && table.contains("<code>c|d</code>"), "转义竖线和代码单元格完整保留")

        for separator in ["|---|---|", "|--|--|", "｜--｜--｜", "｜:--｜--:｜"] {
            let html = AITextToHTML.render("｜公式｜说明｜\n" + separator + "\n｜$|x|$｜绝对值｜")
            check(html.contains("<table>"), "标准及全角短分隔行生成表格：\(separator)")
            check(!html.contains(separator), "表格分隔符不会漏入显示：\(separator)")
            check(latexNodes(html) == ["|x|"], "公式竖线不被表格规范化修改")
        }
        check(AITextToHTML.render("`｜--｜`").contains("<code>｜--｜</code>"), "代码中的分隔结构按字面保留")
        check(AITextToHTML.render("说明 ｜--｜ 是示例").contains("｜--｜"), "无表格上下文不删除普通文本")

        let code = AITextToHTML.render(#"""
        ```swift
        let price = "$5"
        let latex = "$x$"
        <script>alert(1)</script>
        ```
        正文 `$x$` 与 ``a`$y$`b``。
        ~~~text
        $$not math$$
        ~~~
        """#)
        check(latexNodes(code).isEmpty, "围栏和行内代码里的美元符不解析")
        check(occurrences("<pre><code", in: code) == 2, "两类围栏生成代码块")
        check(code.contains("let price = &quot;$5&quot;") || code.contains("let price = \"$5\""), "代码文本保留美元金额")
        check(code.contains("<code>$x$</code>"), "行内代码不做数学转换")
        check(code.contains("<code>a`$y$`b</code>"), "多反引号代码保留内部反引号")
        check(!code.contains("<script>"), "代码中的 HTML 不执行")

        for input in [#"价格 $5 / $10"#, #"总计 $5.00 和 $10.00"#, #"$5$10"#, #"\$x\$"#, #"$ x$"#, #"$x $"#, #"未闭合 $$x"#, #"未闭合 \[x"#, #"未闭合 \(x"#, #"裸公式 \frac{1}{x} + \alpha"#] {
            check(latexNodes(AITextToHTML.render(input)).isEmpty, "金额、转义或无效定界符保留文本：\(input)")
        }
        check(AITextToHTML.render(#"未闭合 $$x"#).contains("$$x"), "未闭合美元定界符不吞文本")
        check(AITextToHTML.render(#"裸公式 \frac{1}{x}"#).contains(#"\frac{1}{x}"#), "裸 LaTeX 不猜测包装")

        let escaping = AITextToHTML.render(#"$a\$b$ 与 \(c<d & e>f\)"#)
        check(latexNodes(escaping) == [#"a\$b"#, "c<d & e>f"], "公式内部转义美元和特殊字符无损")
        let unicode = "e\u{301} + 中文 + 𝛼 + 🧮"
        check(latexNodes(AITextToHTML.render("$" + unicode + "$")).first?.utf8.elementsEqual(unicode.utf8) == true, "组合字符和多字节 UTF8 逐字节保留")

        let markdown = AITextToHTML.render(#"""
        ## **标题** $x$
        - **项目** \(y\)
        1. **第一项** $z$
        2. 第二项
        > **引用** \[w\]
        """#)
        check(markdown.contains("<h2><strong>标题</strong>"), "标题中的粗体与公式共存")
        check(markdown.contains("<ul><li><strong>项目</strong>"), "无序列表中的粗体与公式共存")
        check(markdown.contains("<ol>") && occurrences("<li>", in: markdown) == 3, "有序列表保留独立列表结构")
        check(markdown.contains("<blockquote><strong>引用</strong>"), "引用中的粗体与公式共存")
        check(latexNodes(markdown) == ["x", "y", "z", "w"], "块结构不会破坏公式")

        let injection = AITextToHTML.render(#"<script>alert("x")</script><img src=x onerror=alert(1)> $\text{<script>&}$"#)
        check(!injection.contains("<script>") && !injection.contains("<img"), "原始 HTML 注入保留为转义文本")
        check(injection.contains("&lt;script&gt;"), "正文脚本源码仍可见")
        check(latexNodes(injection) == [#"\text{<script>&}"#], "公式中的脚本形文本只存为无损源码")

        let chart = AITextToHTML.render(#"""
        ```chart
        {"type":"pie","title":"样例","data":[{"label":"甲","value":3},{"label":"乙","value":2}]}
        ```
        """#)
        check(chart.contains("<svg") && chart.contains("样例"), "已有 chart 图表仍生成 SVG")
        check(chart.contains("#5B8FF9"), "图表既有配色不变")
        let invalidChart = AITextToHTML.render("```chart\nnot JSON <&>\n```")
        check(invalidChart.contains("not JSON &lt;&amp;&gt;"), "无效 chart 保留安全源码")
        func chartHTML(_ json: String) -> String { AITextToHTML.render("```chart\n" + json + "\n```") }
        let line = chartHTML(#"{"type":"line","data":[{"label":"一月","value":-2},{"label":"二月","value":3}]}"#)
        check(line.contains("mn-chart-curve") && line.contains("一月") && !line.contains("evenodd"), "line 生成折线而非饼图")
        let numeric = chartHTML(#"{"type":"line","data":[{"x":10,"y":4},{"x":0,"y":0},{"x":1,"y":2}]}"#)
        check(numeric.contains("cx=\"127.200\"") && numeric.contains("cx=\"74.000\""), "数值 x 排序并保留真实间距")
        let gap = chartHTML(#"{"type":"line","data":[{"x":0,"y":1},{"x":1,"y":null},{"x":2,"y":3}]}"#)
        check(gap.contains(" M606.000") && !gap.contains("L606.000"), "缺测数据断开曲线")
        let function = chartHTML(#"{"type":"function","expression":"sin(x)","xMin":-3.14,"xMax":3.14}"#)
        check(function.contains("mn-chart-curve") && !function.contains("<code>"), "函数由本地采样生成")
        let multiple = chartHTML(#"{"type":"function","xMin":-3,"xMax":3,"series":[{"label":"平方","expression":"x^2"},{"label":"正弦","expression":"sin(x)"}]}"#)
        check(occurrences("class=\"mn-chart-curve\"", in: multiple) == 2, "同一坐标系支持多函数")
        let pole = chartHTML(#"{"type":"function","expression":"1/x","xMin":-2,"xMax":2}"#)
        check(pole.contains("mn-chart-curve") && !pole.lowercased().contains("nan") && !pole.lowercased().contains("infinity"), "极点不产生无效 SVG 坐标")
        for (expression, x, expected) in [("-x^2",3.0,-9.0),("2^3^2",0.0,512.0),("2^-2",0.0,0.25),("sin(pi/2)",0.0,1.0),("sqrt(abs(x))",-9.0,3.0),("ln(exp(x))",2.0,2.0),("log10(1e3)",0.0,3.0)] {
            check(abs((CurveExpression(expression)?.value(at:x) ?? .infinity)-expected)<1e-9, "求值及优先级：\(expression)")
        }
        for source in ["alert(1)", "Math.sin(x)", "2x", "sin()", "x +", String(repeating:"(",count:40)+"x"+String(repeating:")",count:40)] {
            check(CurveExpression(source) == nil, "拒绝无效及超深算式：\(source.prefix(30))")
        }
        for json in [#"{"type":"unknown","data":[{"label":"a","value":1}]}"#, #"{"type":"function","expression":"alert(1)"}"#, #"{"type":"function","expression":"sqrt(-1)"}"#, #"{"type":"function","expression":"x","xMin":1,"xMax":1}"#, #"{"type":"function","expression":"x","yMin":3,"yMax":-3}"#, #"{"type":"pie","data":[{"label":"a","value":-1}]}"#, #"{"type":"line","data":[{"x":0,"y":1},{"y":2}]}"#] {
            let html = chartHTML(json)
            check(html.contains("<code>") && !html.contains("<svg"), "无效图表保留源码而非误画图")
        }
        let surface = chartHTML(#"{"type":"surface","title":"马鞍面","expression":"x^2-y^2","xMin":-2,"xMax":2,"yMin":-2,"yMax":2}"#)
        check(surface.contains("mn-surface-chart") && surface.contains("data-surface=") && occurrences("<polygon",in:surface) > 1000, "三维曲面包含实际网格和可恢复数据")
        check(surface.contains("马鞍面") && surface.contains("拖动旋转") && !surface.contains("<script"), "曲面 HTML 保留标题和交互提示，不内嵌脚本")
        check(CurveExpression("x^2-y^2") == nil, "二维曲线不能偷偷把 y 当成零")
        check(CurveExpression("x^2-y^2",variables:["x","y"])?.value(at:3,y:2) == 5, "双变量表达式正确求值")
        for expression in ["0","sin(x)*cos(y)","exp(-x^2-y^2)","sqrt(4-x^2-y^2)","1/(x-y)"] {
            let html = chartHTML("{\"type\":\"surface\",\"expression\":\"" + expression + "\"}")
            check(html.contains("<polygon") && !html.lowercased().contains("nan"), "有效曲面含可见三角面：\(expression)")
        }
        for json in [#"{"type":"surface","expression":"sqrt(-1)"}"#, #"{"type":"surface","expression":"x+y","xMin":1,"xMax":1}"#, #"{"type":"surface","expression":"x+y","yMin":2,"yMax":-2}"#, #"{"type":"surface","expression":"x+y","zMin":3,"zMax":-3}"#, #"{"type":"surface","expression":"Math.sin(x)"}"#, #"{"type":"surface","expression":"x+y","data":[{"value":1}]}"#] {
            let html = chartHTML(json)
            check(html.contains("<code>") && !html.contains("<svg"), "无效曲面不会生成误导图形")
        }
        let escapedSurface = chartHTML(#"{"type":"surface","title":"<script>alert(1)</script>","xLabel":"<img src=x>","expression":"x+y"}"#)
        check(!escapedSurface.contains("<script>") && !escapedSurface.contains("<img") && escapedSurface.contains("&lt;script&gt;"), "三维标题和轴标签不能注入 HTML")
        let area = chartHTML(#"{"type":"area","data":[{"x":0,"y":1},{"x":1,"y":null},{"x":2,"y":3}]}"#)
        check(area.contains("mn-chart-area") && area.contains("mn-chart-curve"), "面积图包含填充与轮廓")
        let areaPath = area.components(separatedBy: "class=\"mn-chart-area\"").last?.components(separatedBy: "d=\"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
        check(occurrences(" Z", in: areaPath) == 2, "缺测值断开面积填充，不跨缺测连线")
        check(areaPath.contains("M74.000,304.000") && areaPath.contains("L606.000,304.000"), "正面积图自动包含零基线")
        let negativeArea = chartHTML(#"{"type":"area","data":[{"value":-4},{"value":-2}]}"#)
        check(negativeArea.contains("M74.000,24.000") && negativeArea.contains("mn-chart-area"), "负面积图填充至顶部零基线")
        let areaFunction = chartHTML(#"{"type":"area","expression":"sin(x)","xMin":-3,"xMax":3}"#)
        check(areaFunction.contains("mn-chart-area"), "面积图支持本地函数采样")
        let scatter = chartHTML(#"{"type":"scatter","data":[{"x":10,"y":4},{"x":0,"y":0},{"x":1,"y":2}]}"#)
        check(occurrences("mn-chart-point", in: scatter) == 3 && !scatter.contains("mn-chart-curve"), "散点图只绘点，不连接数据")
        check(scatter.contains("cx=\"127.200\""), "散点图保留真实 x 间距")
        let densePoints = (0..<150).map { "{\"x\":\($0),\"y\":\($0 % 7)}" }.joined(separator: ",")
        check(occurrences("mn-chart-point", in: chartHTML("{\"type\":\"scatter\",\"data\":[" + densePoints + "]}")) == 150, "散点图超过 100 个观测值仍全部绘制")
        let scatterSeries = chartHTML(#"{"type":"scatter","series":[{"label":"甲","data":[{"x":0,"y":1}]},{"label":"乙","data":[{"x":0,"y":2}]}]}"#)
        check(occurrences("mn-chart-point", in: scatterSeries) == 2 && scatterSeries.contains("#61DDAA"), "散点支持多系列与单点常数范围")
        let radarData = #"[{"label":"速度","value":80},{"label":"质量","value":60},{"label":"成本控制","value":40}]"#
        let radar = chartHTML("{\"type\":\"radar\",\"yMax\":100,\"data\":" + radarData + "}")
        check(radar.contains("mn-radar-chart") && occurrences("mn-radar-grid", in: radar) == 5 && occurrences("mn-radar-series", in: radar) == 1, "雷达图绘制网格与系列")
        check(radar.contains("320.000,73.600") && radar.contains("质量"), "雷达数值按共同尺度准确投影")
        let multipleRadar = chartHTML("{\"type\":\"radar\",\"series\":[{\"label\":\"A\",\"data\":" + radarData + "},{\"label\":\"B\",\"data\":" + radarData + "}]}")
        check(occurrences("mn-radar-series", in: multipleRadar) == 2, "雷达图支持多系列")
        check(chartHTML(#"{"type":"radar","data":[{"label":"a","value":0},{"label":"b","value":0},{"label":"c","value":0}]}"#).contains("mn-radar-chart"), "全零雷达仍有有效坐标尺度")
        let histogram = chartHTML(#"{"type":"histogram","samples":[0,1,2,3,4],"bins":2}"#)
        check(occurrences("mn-histogram-bin", in: histogram) == 2 && histogram.contains("data-count=\"2\"") && histogram.contains("data-count=\"3\""), "直方图分箱边界归右，最大值计入末箱")
        check(histogram.contains("样本数：5") && histogram.contains("频数"), "直方图标明样本数及频数轴")
        let identical = chartHTML(#"{"type":"histogram","samples":[5,5,5],"bins":1}"#)
        check(identical.contains("data-count=\"3\"") && !identical.contains("nan"), "相同样本安全扩展范围")
        let negativeHistogram = chartHTML(#"{"type":"histogram","samples":[-2,-1,0,1,2],"bins":2,"xMin":-3,"xMax":3}"#)
        check(negativeHistogram.contains("data-count=\"2\"") && negativeHistogram.contains("data-count=\"3\""), "直方图支持负值及显式宽范围")
        check(chartHTML(#"{"type":"histogram","samples":[1,2,3,4]}"#).contains("等宽分箱：2"), "直方图默认使用样本数平方根分箱")
        let hugeHistogram = chartHTML(#"{"type":"histogram","samples":[0,1e308],"bins":2}"#)
        check(hugeHistogram.contains("mn-histogram-chart") && !hugeHistogram.lowercased().contains("inf"), "极大有限值不会溢出为无效分箱坐标")
        for json in [
            #"{"type":"scatter","data":[{"value":1}]}"#,
            #"{"type":"scatter","expression":"sin(x)"}"#,
            #"{"type":"radar","data":[{"label":"a","value":1},{"label":"b","value":2}]}"#,
            #"{"type":"radar","data":[{"label":"a","value":-1},{"label":"b","value":2},{"label":"c","value":3}]}"#,
            #"{"type":"radar","data":[{"label":"a","value":1},{"label":"a","value":2},{"label":"c","value":3}]}"#,
            #"{"type":"radar","yMax":1,"data":[{"label":"a","value":1},{"label":"b","value":2},{"label":"c","value":3}]}"#,
            #"{"type":"radar","series":[{"data":[{"label":"a","value":1},{"label":"b","value":2},{"label":"c","value":3}]},{"data":[{"label":"b","value":1},{"label":"a","value":2},{"label":"c","value":3}]}]}"#,
            #"{"type":"histogram","samples":[]}"#,
            #"{"type":"histogram","samples":[1],"bins":0}"#,
            #"{"type":"histogram","samples":[1],"bins":51}"#,
            #"{"type":"histogram","samples":[1],"bins":1.5}"#,
            #"{"type":"histogram","samples":[1,5],"xMax":3}"#,
            #"{"type":"histogram","samples":[1,1],"yMax":1}"#,
            #"{"type":"histogram","samples":[1],"data":[{"value":1}]}"#,
            #"{"type":"histogram","samples":[1],"yMin":1}"#
        ] {
            let html = chartHTML(json)
            check(html.contains("<code>") && !html.contains("<svg"), "无效新增图表安全保留源码")
        }
        let escapedRadar = chartHTML(#"{"type":"radar","title":"<script>x</script>","data":[{"label":"<img>","value":1},{"label":"b","value":2},{"label":"c","value":3}]}"#)
        check(escapedRadar.contains("&lt;img&gt;") && !escapedRadar.contains("<script>") && !escapedRadar.contains("<img>"), "新增图表标题和指标安全转义")
        let unclosedCode = AITextToHTML.render("```text\n$x$\n\n$y$")
        check(latexNodes(unclosedCode).isEmpty && unclosedCode.contains("<pre><code"), "未闭合围栏仍保护后续代码")

        #if MATH_MARKUP_AVAILABLE
        let node = MathMarkup.node(latex: fraction, display: true)
        check(latexNodes(node) == [fraction], "公开 node API 遵循 Base64 契约")
        check(node.hasPrefix("<span class=\"mn-math mn-math-display\"") && node.hasSuffix("</span>"), "公开 node API 返回稳定 span")
        #endif

        print("\(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
