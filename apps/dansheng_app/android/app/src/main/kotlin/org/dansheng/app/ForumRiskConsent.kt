// SPDX-License-Identifier: GPL-3.0-or-later
package org.dansheng.app

import org.dansheng.android.PortError

/** Local acknowledgement only. It never grants permission from the forum operator. */
internal class ForumRiskConsent(
    private val readVersion: (String) -> Int,
    private val writeVersion: (String, Int?) -> Unit,
) {
    fun requireAccepted(account: String) {
        if (readVersion(account) != VERSION) throw PortError("ForumConsentRequired")
    }

    suspend fun authorize(
        account: String,
        confirm: (suspend () -> Unit)?,
        withAccount: (() -> Unit) -> Unit,
    ) {
        withAccount { if (confirm == null) requireAccepted(account) }
        if (confirm == null) {
            return
        }
        // Every explicit login shows the notice, even if background restoration is allowed.
        confirm()
        withAccount { writeVersion(account, VERSION) }
    }

    fun forget(account: String) = writeVersion(account, null)

    companion object {
        const val VERSION = 1
        const val TITLE = "复旦树洞使用风险与免责声明"
        const val MESSAGE = "Dansheng 是第三方客户端，并非复旦树洞（旦挞茶楼）官方客户端。\n\n" +
            "社区使用协议要求第三方客户端、脚本访问及下载内容取得管理团队明确许可。" +
            "使用本功能可能导致访问受限、账号停用或封禁；接口变化也可能造成服务中断或数据显示异常。\n\n" +
            "请自行确认使用资格和所需许可，遵守社区规则，保护账号及他人隐私。" +
            "本次确认不代表社区授权，也不授权批量抓取、传播社区内容或将内容上传至外部 AI 服务。\n\n" +
            "您理解并自愿承担因使用第三方客户端、违反社区规则或自身操作产生的相应风险。" +
            "本应用不保证账号安全或服务持续可用；本声明不排除依法不得免除的责任。"
        const val ACKNOWLEDGEMENT = "我已阅读并理解上述风险及免责声明，自愿继续使用并承担相应风险"
        const val AGREEMENT_LABEL = "查看《旦挞社区服务使用协议》"
        const val AGREEMENT_URL = "https://danxi.fduhole.com/doc/community-user-agreement"
        fun key(account: String) = "forum-risk-consent/$account"
    }
}
