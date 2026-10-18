import Foundation

/// 一个可切换的「技能」：本质是一段追加到 system prompt 的行为规范。
///
/// 为什么不叫 prompt 模板：模板强调"换个说法问"，技能强调"换一套做事方式"。
/// 重构要产出结构化 HTML，总结要压缩，答疑要克制不改内容——三者对模型的约束
/// 是不同的，混在一个 prompt 里会互相打架。
struct AISkill: Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var summary: String
    /// 追加到 system prompt 末尾的规范。空字符串表示不做额外约束。
    var instructions: String

    static let all: [AISkill] = [
        AISkill(
            id: "chat",
            name: "对话",
            icon: "bubble.left.and.bubble.right",
            summary: "正常问答，回答可直接复制回笔记",
            instructions: """
            当前模式：普通对话。
            直接回答问题。给结论，不要复述用户的话。需要给内容时，用 Markdown 组织。
            """
        ),
        AISkill(
            id: "restructure",
            name: "重构",
            icon: "text.alignleft",
            summary: "把正文改写成结构化的层级",
            instructions: """
            当前模式：笔记重构。
            目标是把混乱的内容整理成清晰结构，**不新增事实、不改变原意**。
            规则：
            1. 先判断这段内容在讲什么，再决定层级：主标题用 `##`，子项用 `###`。
            2. 并列内容用无序列表；有先后顺序的用有序列表。
            3. 公式一律用 LaTeX（`$…$` 或 `$$…$$`）；占比/对比用 `chart` 代码块。
            4. 原文里的事实、数字、专有名词一个字都不能改。
            5. 只输出整理后的正文，不要写"以下是整理结果"这类前言。
            """
        ),
        AISkill(
            id: "summary",
            name: "总结",
            icon: "text.append",
            summary: "压成要点，保留关键数字",
            instructions: """
            当前模式：总结。
            规则：
            1. 最多 5 条要点，每条不超过 30 字。
            2. 数字、日期、专有名词必须保留；形容词、连接词可以砍掉。
            3. 用无序列表输出，不加总结性开场。
            4. 如果原文本身已经很短，直接说「原文已足够精炼」，不要硬压。
            """
        ),
        AISkill(
            id: "qa",
            name: "答疑",
            icon: "questionmark.circle",
            summary: "基于当前笔记回答，不改动正文",
            instructions: """
            当前模式：答疑。
            规则：
            1. 优先用当前笔记里的内容回答，引用时说明出自哪一段。
            2. 笔记里没写的内容，明确说「笔记里没有这部分」，不要编。
            3. 不修改正文，不输出可直接替换全文的内容——除非用户明确要求。
            """
        ),
    ]
}
