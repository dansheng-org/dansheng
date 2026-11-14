/**
 * Dansheng 本地实验台前端逻辑
 * 纯客户端原生 JS，不依赖外部库，内存存储 CSRF Token，不写任何 storage，无 console.log
 */
'use strict';

(function () {
  // 内存状态（绝不存入 localStorage/sessionStorage）
  const state = {
    csrfToken: null,
    inFlight: false,
    credentialsStored: false,
    sessionAuthenticated: false,
  };

  // DOM 元素缓存
  const el = {
    // 顶部运行时标签
    tagRuntimeMode: document.getElementById('tag-runtime-mode'),
    tagRuntimeVersion: document.getElementById('tag-runtime-version'),
    tagCoreStatus: document.getElementById('tag-core-status'),

    // 全局横幅
    globalBanner: document.getElementById('global-banner'),
    globalBannerText: document.getElementById('global-banner-text'),

    // 流程指示
    stepCred: document.getElementById('step-cred'),
    pipelineCredState: document.getElementById('pipeline-cred-state'),
    stepSession: document.getElementById('step-session'),
    pipelineSessionState: document.getElementById('pipeline-session-state'),
    stepProbe: document.getElementById('step-probe'),
    pipelineProbeState: document.getElementById('pipeline-probe-state'),

    // 第一区：账号凭据
    credStatusDot: document.getElementById('cred-status-dot'),
    credStatusText: document.getElementById('cred-status-text'),
    credHintValue: document.getElementById('cred-hint-value'),
    formCredentials: document.getElementById('form-credentials'),
    inputStudentId: document.getElementById('input-student-id'),
    inputPassword: document.getElementById('input-password'),
    btnSaveCredentials: document.getElementById('btn-save-credentials'),
    btnDeleteCredentials: document.getElementById('btn-delete-credentials'),
    credFeedback: document.getElementById('cred-feedback'),

    // 第二区：来源登录
    sessionStatusDot: document.getElementById('session-status-dot'),
    sessionStatusText: document.getElementById('session-status-text'),
    metaSessionAuth: document.getElementById('meta-session-auth'),
    metaLastTarget: document.getElementById('meta-last-target'),
    metaSessionVerification: document.getElementById('meta-session-verification'),
    btnLoginTarget: document.getElementById('btn-login-target'),
    loginInteractiveAlert: document.getElementById('login-interactive-alert'),
    loginFeedback: document.getElementById('login-feedback'),

    // 第三区：只读测试
    probeStatusDot: document.getElementById('probe-status-dot'),
    probeStatusText: document.getElementById('probe-status-text'),
    btnRunProbe: document.getElementById('btn-run-probe'),
    probeLoadingIndicator: document.getElementById('probe-loading-indicator'),
    probeResultBox: document.getElementById('probe-result-box'),
    probeResultBadge: document.getElementById('probe-result-badge'),
    probeResultName: document.getElementById('probe-result-name'),
    probeResultElapsed: document.getElementById('probe-result-elapsed'),
    probeResultMessage: document.getElementById('probe-result-message'),
    probeResultCountRow: document.getElementById('probe-result-count-row'),
    probeResultCount: document.getElementById('probe-result-count'),
    probeResultJson: document.getElementById('probe-result-json'),

    // 模态对话框
    modalDelete: document.getElementById('modal-delete'),
    modalDeleteCancel: document.getElementById('modal-delete-cancel'),
    modalDeleteConfirm: document.getElementById('modal-delete-confirm'),
  };

  // 映射中文名称字典
  const TARGET_NAMES = {
    academic: '学术教务系统',
    canvas: 'Canvas 在线学习平台',
    ecard: '校园一卡通系统',
  };

  const PROBE_NAMES = {
    core: 'Core 核心状态',
    public_notices: '公共通知',
    academic_semesters: '教务学期列表',
    canvas_courses: 'Canvas 课程列表',
    cache: '缓存状态',
  };

  /**
   * 安全网络请求封装
   * - 统一 credentials: 'same-origin'
   * - 变更请求附带 X-CSRF-Token
   * - 65 秒客户端超时控制（适应校内站点长请求）
   * - 错误仅提取后端 safe message，绝不向 DOM 序列化异常对象
   */
  async function safeFetch(url, options = {}) {
    const method = (options.method || 'GET').toUpperCase();
    const headers = Object.assign({}, options.headers || {});

    if (method !== 'GET' && method !== 'HEAD') {
      if (!headers['Content-Type']) {
        headers['Content-Type'] = 'application/json';
      }
      if (state.csrfToken) {
        headers['X-CSRF-Token'] = state.csrfToken;
      }
    }

    const controller = new AbortController();
    const timeoutId = setTimeout(function () {
      controller.abort();
    }, 65000);

    let response;
    try {
      response = await fetch(url, {
        method: method,
        headers: headers,
        body: options.body,
        credentials: 'same-origin',
        signal: controller.signal,
      });
    } catch (netErr) {
      clearTimeout(timeoutId);
      if (netErr && netErr.name === 'AbortError') {
        throw { code: 'REQUEST_TIMEOUT', message: '请求超时（已超过65秒），学校站点响应未完成，请稍后重试' };
      }
      throw { code: 'NETWORK_ERROR', message: '网络连接失败，请确认本地服务正在运行' };
    } finally {
      clearTimeout(timeoutId);
    }

    let payload = null;
    const contentType = response.headers.get('content-type') || '';
    if (contentType.includes('application/json')) {
      try {
        payload = await response.json();
      } catch (_) {
        payload = null;
      }
    }

    if (!response.ok) {
      if (response.status === 401) {
        state.csrfToken = null;
        showGlobalBanner('会话已失效或未授权 (401)，请使用启动脚本重新打开实验台页面。', 'danger');
        setInFlight(true);
      }
      const code = (payload && payload.error && payload.error.code) ? payload.error.code : ('HTTP_' + response.status);
      const message = (payload && payload.error && payload.error.message) ? payload.error.message : ('服务请求失败 (状态码 ' + response.status + ')');
      throw { code: code, message: message, status: response.status, details: payload };
    }

    return payload;
  }

  /**
   * 从 URL Hash 读取 token 并立刻清除 fragment
   */
  function extractAndClearHashToken() {
    const rawHash = window.location.hash ? window.location.hash.substring(1) : '';
    if (!rawHash) {
      return null;
    }
    let token = null;
    try {
      const params = new URLSearchParams(rawHash);
      token = params.get('token');
      if (!token && rawHash.startsWith('token=')) {
        token = rawHash.slice(6);
      } else if (!token && !rawHash.includes('=')) {
        token = rawHash;
      }
    } catch (_) {
      token = null;
    }
    // 立刻清除 fragment 避免泄露在浏览器历史
    window.history.replaceState(null, '', window.location.pathname + window.location.search);
    return token ? token.trim() : null;
  }

  /**
   * 设置全局横幅提示
   */
  function showGlobalBanner(message, type) {
    if (!el.globalBanner || !el.globalBannerText) return;
    el.globalBannerText.textContent = message;
    el.globalBanner.className = 'banner ' + (type === 'danger' ? 'banner-danger' : 'banner-warning');
    el.globalBanner.classList.remove('hidden');
  }

  /**
   * 设置反馈消息（纯文本防 XSS）
   */
  function showFeedback(targetEl, message, isSuccess) {
    if (!targetEl) return;
    targetEl.textContent = message;
    targetEl.className = 'feedback-msg ' + (isSuccess ? 'feedback-success' : 'feedback-error');
    targetEl.classList.remove('hidden');
  }

  function clearFeedback(targetEl) {
    if (!targetEl) return;
    targetEl.textContent = '';
    targetEl.className = 'feedback-msg hidden';
  }

  /**
   * 控制请求在途状态与操作按钮禁用
   */
  function setInFlight(busy) {
    state.inFlight = busy;
    const unavailable = busy || !state.csrfToken;
    if (el.btnSaveCredentials) el.btnSaveCredentials.disabled = unavailable;
    if (el.btnDeleteCredentials) el.btnDeleteCredentials.disabled = unavailable;
    if (el.btnLoginTarget) el.btnLoginTarget.disabled = unavailable || !state.credentialsStored;
    if (el.btnRunProbe) el.btnRunProbe.disabled = unavailable;
  }

  /**
   * 刷新系统状态 GET /api/status
   */
  async function fetchStatus() {
    try {
      const data = await safeFetch('/api/status', { method: 'GET' });
      if (!data) return;

      // 运行时信息
      if (data.runtime) {
        if (el.tagRuntimeMode && data.runtime.mode) {
          el.tagRuntimeMode.textContent = '仅本机 · 测试环境';
        }
        if (el.tagRuntimeVersion && data.runtime.version) {
          el.tagRuntimeVersion.textContent = 'v' + data.runtime.version;
        }
        if (el.tagCoreStatus) {
          if (data.runtime.core_available) {
            el.tagCoreStatus.textContent = 'Core 就绪';
            el.tagCoreStatus.className = 'tag tag-green';
          } else {
            el.tagCoreStatus.textContent = 'Core 未就绪';
            el.tagCoreStatus.className = 'tag tag-slate';
          }
        }
      }

      // 第一区：凭据状态
      state.credentialsStored = Boolean(data.credentials && data.credentials.stored);
      if (state.credentialsStored) {
        if (el.credStatusDot) el.credStatusDot.className = 'status-dot dot-success';
        if (el.credStatusText) el.credStatusText.textContent = '已加密保存';
        if (el.credHintValue) {
          el.credHintValue.textContent = (data.credentials && data.credentials.username_hint)
            ? data.credentials.username_hint
            : '已保存（掩码保护）';
        }
        if (el.btnDeleteCredentials) el.btnDeleteCredentials.classList.remove('hidden');
        if (el.stepCred) el.stepCred.className = 'pipeline-step completed';
        if (el.pipelineCredState) el.pipelineCredState.textContent = '已保存';
      } else {
        if (el.credStatusDot) el.credStatusDot.className = 'status-dot dot-neutral';
        if (el.credStatusText) el.credStatusText.textContent = '未保存凭据';
        if (el.credHintValue) el.credHintValue.textContent = '未设定';
        if (el.btnDeleteCredentials) el.btnDeleteCredentials.classList.add('hidden');
        if (el.stepCred) el.stepCred.className = 'pipeline-step';
        if (el.pipelineCredState) el.pipelineCredState.textContent = '未保存';
      }

      // 第二区：会话状态
      state.sessionAuthenticated = Boolean(data.session && data.session.authenticated);
      if (state.sessionAuthenticated) {
        if (el.sessionStatusDot) el.sessionStatusDot.className = 'status-dot dot-success';
        if (el.sessionStatusText) el.sessionStatusText.textContent = '会话已导入';
        if (el.metaSessionAuth) el.metaSessionAuth.textContent = '本地会话已加载，待业务验证';
        if (el.stepSession) el.stepSession.className = 'pipeline-step completed';
        if (el.pipelineSessionState) el.pipelineSessionState.textContent = '已导入';
      } else {
        if (el.sessionStatusDot) el.sessionStatusDot.className = 'status-dot dot-neutral';
        if (el.sessionStatusText) el.sessionStatusText.textContent = '会话未导入';
        if (el.metaSessionAuth) el.metaSessionAuth.textContent = '未导入';
        if (el.stepSession) el.stepSession.className = 'pipeline-step';
        if (el.pipelineSessionState) el.pipelineSessionState.textContent = '未导入';
      }

      if (el.metaSessionVerification) {
        el.metaSessionVerification.textContent = (data.session && data.session.verification)
          ? '仅确认本地凭据存在'
          : '尚未验证';
      }

      if (el.metaLastTarget) {
        if (data.last_login && data.last_login.target) {
          const targetZh = TARGET_NAMES[data.last_login.target] || data.last_login.target;
          const stateZh = data.last_login.state === 'token_verified' ? '令牌身份已验证' : (data.last_login.state === 'session_imported' ? '已导入' : '未完成');
          el.metaLastTarget.textContent = targetZh + ' (' + stateZh + ')';
        } else {
          el.metaLastTarget.textContent = '无';
        }
      }
    } catch (_) {
      // safeFetch 内部处理错误状态
    }
  }

  /**
   * 初始化会话与 CSRF Token
   */
  async function initSession() {
    const token = extractAndClearHashToken();
    try {
      let sessionData;
      if (token) {
        // 从 URL fragment 获取了临时启动 token
        sessionData = await safeFetch('/api/session', {
          method: 'POST',
          body: JSON.stringify({ token: token }),
        });
      } else {
        // 无 token，尝试恢复已存在的 HttpOnly cookie
        sessionData = await safeFetch('/api/session', {
          method: 'GET',
        });
      }

      if (sessionData && sessionData.csrf_token) {
        state.csrfToken = sessionData.csrf_token;
      }

      await fetchStatus();
      setInFlight(false);
    } catch (err) {
      if (err && err.status === 401) {
        showGlobalBanner('未授权或会话已过期 (401)，请使用启动脚本重新打开实验台页面。', 'danger');
      } else {
        showGlobalBanner('实验台初始化通信失败：' + (err && err.message ? err.message : '请确认本地服务正常运行'), 'warning');
      }
    }
  }

  /**
   * 保存账号凭据 POST /api/credentials
   */
  async function handleSaveCredentials(e) {
    e.preventDefault();
    if (state.inFlight) return;
    clearFeedback(el.credFeedback);

    const studentId = el.inputStudentId.value.trim();
    const password = el.inputPassword.value;

    if (!studentId || !password) {
      showFeedback(el.credFeedback, '请完整输入学号/工号与统一身份认证密码', false);
      return;
    }

    setInFlight(true);
    const originalText = el.btnSaveCredentials.textContent;
    el.btnSaveCredentials.textContent = '正在加密保存...';

    try {
      const res = await safeFetch('/api/credentials', {
        method: 'POST',
        body: JSON.stringify({ student_id: studentId, password: password }),
      });

      // 成功清空输入框，密码绝不停留在输入控件中
      el.inputStudentId.value = '';
      el.inputPassword.value = '';
      if (el.stepProbe) el.stepProbe.className = 'pipeline-step';
      if (el.pipelineProbeState) el.pipelineProbeState.textContent = '未测试';
      if (el.probeResultBox) el.probeResultBox.classList.add('hidden');

      const hintText = (res && res.username_hint) ? ('（账号掩码：' + res.username_hint + '）') : '';
      showFeedback(el.credFeedback, '凭据已在本机加密保存' + hintText + '。保存仅在本机，不触发实际登录。', true);

      await fetchStatus();
    } catch (err) {
      showFeedback(el.credFeedback, '凭据保存失败：' + (err && err.message ? err.message : '未知错误'), false);
    } finally {
      el.btnSaveCredentials.textContent = originalText;
      setInFlight(false);
    }
  }

  /**
   * 打开删除凭据确认模态框
   */
  function openDeleteModal() {
    if (state.inFlight) return;
    if (el.modalDelete) {
      el.modalDelete.classList.remove('hidden');
    }
  }

  /**
   * 关闭删除凭据确认模态框
   */
  function closeDeleteModal() {
    if (el.modalDelete) {
      el.modalDelete.classList.add('hidden');
    }
  }

  /**
   * 确认删除本地凭据 DELETE /api/credentials
   */
  async function handleConfirmDeleteCredentials() {
    closeDeleteModal();
    if (state.inFlight) return;
    clearFeedback(el.credFeedback);

    setInFlight(true);
    try {
      await safeFetch('/api/credentials', {
        method: 'DELETE',
        body: JSON.stringify({}),
      });

      showFeedback(el.credFeedback, '已成功清除本地凭据与所有关联会话。', true);
      // 清理第二区和第三区的状态显示
      if (el.loginInteractiveAlert) el.loginInteractiveAlert.classList.add('hidden');
      clearFeedback(el.loginFeedback);
      if (el.stepProbe) el.stepProbe.className = 'pipeline-step';
      if (el.pipelineProbeState) el.pipelineProbeState.textContent = '未测试';
      if (el.probeStatusDot) el.probeStatusDot.className = 'status-dot dot-neutral';
      if (el.probeStatusText) el.probeStatusText.textContent = '未测试';
      if (el.probeResultBox) el.probeResultBox.classList.add('hidden');

      await fetchStatus();
    } catch (err) {
      showFeedback(el.credFeedback, '清除失败：' + (err && err.message ? err.message : '未知错误'), false);
    } finally {
      setInFlight(false);
    }
  }

  /**
   * 来源登录 POST /api/login
   */
  async function handleLoginTarget() {
    if (state.inFlight) return;
    if (el.stepProbe) el.stepProbe.className = 'pipeline-step';
    if (el.pipelineProbeState) el.pipelineProbeState.textContent = '未测试';
    clearFeedback(el.loginFeedback);
    if (el.loginInteractiveAlert) {
      el.loginInteractiveAlert.classList.add('hidden');
    }

    const checkedRadio = document.querySelector('input[name="login_target"]:checked');
    const target = checkedRadio ? checkedRadio.value : 'academic';
    const targetZh = TARGET_NAMES[target] || target;

    setInFlight(true);
    const originalText = el.btnLoginTarget.textContent;
    el.btnLoginTarget.textContent = '正在向学校认证源验证（最长可能需要60秒）...';

    try {
      const res = await safeFetch('/api/login', {
        method: 'POST',
        body: JSON.stringify({ target: target }),
      });

      const message = (res && res.message) ? res.message : '会话导入成功';
      showFeedback(el.loginFeedback, targetZh + '：' + message + '。请在下方【第三区】执行只读测试以验证可用性。', true);

      await fetchStatus();
    } catch (err) {
      if (err && err.code === 'InteractiveLoginRequired') {
        if (el.loginInteractiveAlert) {
          el.loginInteractiveAlert.classList.remove('hidden');
        }
        showFeedback(el.loginFeedback, '登录需交互核验：' + (err.message || '请在学校认证页面完成二次核验后再试'), false);
      } else {
        showFeedback(el.loginFeedback, '登录验证失败：' + (err && err.message ? err.message : '请求失败'), false);
      }
    } finally {
      el.btnLoginTarget.textContent = originalText;
      setInFlight(false);
    }
  }

  /**
   * 执行只读测试 POST /api/probe
   */
  async function handleRunProbe() {
    if (state.inFlight) return;

    const checkedRadio = document.querySelector('input[name="probe_type"]:checked');
    const probe = checkedRadio ? checkedRadio.value : 'core';
    const probeZh = PROBE_NAMES[probe] || probe;

    // 显示加载状态
    if (el.probeLoadingIndicator) {
      el.probeLoadingIndicator.classList.remove('hidden');
    }
    if (el.probeResultBox) {
      el.probeResultBox.classList.add('hidden');
    }

    setInFlight(true);
    const originalText = el.btnRunProbe.textContent;
    el.btnRunProbe.textContent = '测试执行中...';
    const startTime = performance.now();

    try {
      const res = await safeFetch('/api/probe', {
        method: 'POST',
        body: JSON.stringify({ probe: probe }),
      });

      const elapsed = (res && typeof res.elapsed_ms === 'number')
        ? res.elapsed_ms
        : Math.round(performance.now() - startTime);

      // 展示成功结果
      if (el.probeResultBox) el.probeResultBox.classList.remove('hidden');
      if (el.probeResultName) el.probeResultName.textContent = probeZh;
      if (el.probeResultElapsed) el.probeResultElapsed.textContent = elapsed + ' ms';
      if (el.probeResultBadge) {
        el.probeResultBadge.textContent = '测试通过';
        el.probeResultBadge.className = 'result-badge badge-success';
      }

      if (el.probeResultMessage) {
        el.probeResultMessage.textContent = (res && res.summary && res.summary.message)
          ? res.summary.message
          : '只读接口调用成功';
      }

      if (el.probeResultCountRow && el.probeResultCount) {
        if (res && res.summary && typeof res.summary.count === 'number') {
          el.probeResultCount.textContent = String(res.summary.count);
          el.probeResultCountRow.classList.remove('hidden');
        } else {
          el.probeResultCountRow.classList.add('hidden');
        }
      }

      // 原始 JSON 输出，严格使用 textContent 防 XSS
      if (el.probeResultJson) {
        const rawResult = (res && res.result !== undefined) ? res.result : res;
        el.probeResultJson.textContent = JSON.stringify(rawResult, null, 2);
      }

      // 更新只读测试区域指示与流程步骤
      if (el.probeStatusDot) el.probeStatusDot.className = 'status-dot dot-success';
      const privateRead = probe === 'academic_semesters' || probe === 'canvas_courses';
      if (el.probeStatusText) el.probeStatusText.textContent = privateRead ? '业务读取通过' : (probe === 'public_notices' ? '公开读取通过' : '本地检查通过');
      if (el.stepProbe) el.stepProbe.className = privateRead ? 'pipeline-step completed' : 'pipeline-step';
      if (el.pipelineProbeState) el.pipelineProbeState.textContent = privateRead ? probeZh + '已通过' : '私有来源待验证';
    } catch (err) {
      const elapsed = Math.round(performance.now() - startTime);

      if (el.probeResultBox) el.probeResultBox.classList.remove('hidden');
      if (el.probeResultName) el.probeResultName.textContent = probeZh;
      if (el.probeResultElapsed) el.probeResultElapsed.textContent = elapsed + ' ms';
      if (el.probeResultBadge) {
        el.probeResultBadge.textContent = '测试未通过';
        el.probeResultBadge.className = 'result-badge badge-danger';
      }

      if (el.probeResultMessage) {
        el.probeResultMessage.textContent = (err && err.message) ? err.message : '只读探测执行失败';
      }

      if (el.probeResultCountRow) {
        el.probeResultCountRow.classList.add('hidden');
      }

      if (el.probeResultJson) {
        el.probeResultJson.textContent = JSON.stringify({
          error: {
            code: (err && err.code) ? err.code : 'PROBE_FAILED',
            message: (err && err.message) ? err.message : '只读探测执行异常',
          },
        }, null, 2);
      }

      if (el.probeStatusDot) el.probeStatusDot.className = 'status-dot dot-danger';
      if (el.probeStatusText) el.probeStatusText.textContent = '测试失败';
      if (el.stepProbe) el.stepProbe.className = 'pipeline-step';
      if (el.pipelineProbeState) el.pipelineProbeState.textContent = '未通过';
    } finally {
      if (el.probeLoadingIndicator) {
        el.probeLoadingIndicator.classList.add('hidden');
      }
      el.btnRunProbe.textContent = originalText;
      setInFlight(false);
    }
  }

  /**
   * 绑定目标与探测单选卡片点击高亮
   */
  function setupSelectionCards() {
    // 第二区单选目标卡片
    const targetRadios = document.querySelectorAll('input[name="login_target"]');
    targetRadios.forEach(function (radio) {
      radio.addEventListener('change', function () {
        document.querySelectorAll('.target-card').forEach(function (c) {
          c.classList.remove('active');
        });
        const parentLabel = radio.closest('.target-card');
        if (parentLabel) parentLabel.classList.add('active');
      });
    });

    // 第三区单选探测卡片
    const probeRadios = document.querySelectorAll('input[name="probe_type"]');
    probeRadios.forEach(function (radio) {
      radio.addEventListener('change', function () {
        document.querySelectorAll('.probe-card').forEach(function (c) {
          c.classList.remove('active');
        });
        const parentLabel = radio.closest('.probe-card');
        if (parentLabel) parentLabel.classList.add('active');
      });
    });
  }

  /**
   * 初始化事件监听
   */
  function initEvents() {
    // 凭据表单提交
    if (el.formCredentials) {
      el.formCredentials.addEventListener('submit', handleSaveCredentials);
    }

    // 凭据删除确认
    if (el.btnDeleteCredentials) {
      el.btnDeleteCredentials.addEventListener('click', openDeleteModal);
    }
    if (el.modalDeleteCancel) {
      el.modalDeleteCancel.addEventListener('click', closeDeleteModal);
    }
    if (el.modalDeleteConfirm) {
      el.modalDeleteConfirm.addEventListener('click', handleConfirmDeleteCredentials);
    }

    // 来源登录
    if (el.btnLoginTarget) {
      el.btnLoginTarget.addEventListener('click', handleLoginTarget);
    }

    // 只读测试
    if (el.btnRunProbe) {
      el.btnRunProbe.addEventListener('click', handleRunProbe);
    }

    // 点击模态遮罩外层关闭
    if (el.modalDelete) {
      el.modalDelete.addEventListener('click', function (e) {
        if (e.target === el.modalDelete) {
          closeDeleteModal();
        }
      });
    }

    // Esc 按键关闭模态
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && el.modalDelete && !el.modalDelete.classList.contains('hidden')) {
        closeDeleteModal();
      }
    });

    setupSelectionCards();
  }

  // 页面加载启动
  document.addEventListener('DOMContentLoaded', function () {
    initEvents();
    setInFlight(true);
    initSession();
  });
})();
