// SPDX-License-Identifier: GPL-3.0-or-later
import { fault } from '../policy.mjs';
import { readFileSync } from 'node:fs';

export const HOST_POLICY = JSON.parse(
  readFileSync(new URL('../host-policy.json', import.meta.url), 'utf8')
);

/**
 * Resolves an RFC 6901 JSON pointer against an object.
 */
export function resolveJsonPointer(obj, pointer) {
  if (!pointer || pointer === '') return obj;
  if (!pointer.startsWith('/')) return undefined;
  const parts = pointer.slice(1).split('/').map(p => p.replace(/~1/g, '/').replace(/~0/g, '~'));
  let current = obj;
  for (const part of parts) {
    if (current == null || typeof current !== 'object') return undefined;
    if (Array.isArray(current)) {
      const idx = Number(part);
      if (!Number.isSafeInteger(idx) || idx < 0 || idx >= current.length) return undefined;
      current = current[idx];
    } else {
      current = current[part];
    }
  }
  return current;
}

/**
 * Evaluates host identity probe according to binding_v1 contract.
 * If no authoritative JSON pointer is present, explicitly fails closed with IdentityVerificationUnavailable.
 * Never infers identity without evidence.
 */
export function verifyIdentityProbe(expectedAccount, probeSession, probeConfig) {
  if (!expectedAccount || typeof expectedAccount !== 'string') {
    throw fault('InvalidAccount');
  }
  if (!probeSession || probeSession.authenticated !== true) {
    throw fault('AuthenticationRequired');
  }
  // If identity probe is not supported or missing json_pointer, fail closed
  if (!probeConfig || !probeConfig.json_pointer || typeof probeConfig.json_pointer !== 'string') {
    throw fault('IdentityVerificationUnavailable');
  }
  if (probeConfig.method && probeConfig.method !== 'GET') {
    throw fault('IdentityVerificationUnavailable');
  }
  const extracted = resolveJsonPointer(probeSession.body, probeConfig.json_pointer);
  if (typeof extracted !== 'string' || extracted !== expectedAccount) {
    throw fault('AccountMismatch');
  }
  return {
    verified: true,
    account_id: extracted,
  };
}

/**
 * Evaluates the binding_v1 key template array into a concrete mutation_key string.
 */
export function evaluateKey(keyTokens, consentInput, row = null, choice = null, round = 1) {
  const parts = [];
  for (const token of keyTokens) {
    if (typeof token === 'string') {
      parts.push(token);
    } else if (token && typeof token === 'object') {
      if (token.$input) {
        parts.push(String(consentInput[token.$input] ?? ''));
      } else if (token.$row) {
        parts.push(String(row ? (row[token.$row] ?? '') : ''));
      } else if (token.$choice === true) {
        parts.push(String(choice ?? ''));
      } else if (token.$positiveInteger === true) {
        if (!Number.isSafeInteger(round) || round <= 0) {
          parts.push('');
        } else {
          parts.push(String(round));
        }
      }
    }
  }
  return parts.join(':');
}

/**
 * Evaluates a form field template against consent input, current row, and choice.
 */
export function evaluateFormValue(template, consentInput, row = null, choice = null) {
  if (template === null || template === undefined) return template;
  if (typeof template === 'string') return template;
  if (typeof template === 'number' || typeof template === 'boolean') return template;
  if (Array.isArray(template)) {
    return template.map(item => evaluateFormValue(item, consentInput, row, choice));
  }
  if (typeof template === 'object') {
    if (template.$text) return String(evaluateFormValue(template.$text, consentInput, row, choice));
    if (template.$input) {
      return consentInput[template.$input];
    }
    if (template.$row) {
      return row ? row[template.$row] : undefined;
    }
    if (template.$choice === true) {
      return choice;
    }
    if (template.$json !== undefined) {
      const evaluated = evaluateFormValue(template.$json, consentInput, row, choice);
      return JSON.stringify(evaluated);
    }
    const result = {};
    for (const [k, v] of Object.entries(template)) {
      result[k] = evaluateFormValue(v, consentInput, row, choice);
    }
    return result;
  }
  return template;
}

/**
 * Evaluates complete expected form fields map from rule.form template.
 */
export function evaluateForm(formTemplate, consentInput, row = null, choice = null) {
  const result = {};
  for (const [key, tpl] of Object.entries(formTemplate)) {
    const val = evaluateFormValue(tpl, consentInput, row, choice);
    result[key] = typeof val === 'object' && val !== null ? JSON.stringify(val) : String(val);
  }
  return result;
}

/**
 * Validates whether an outgoing page request matches any rule in binding_v1 for given consent input.
 */
export function matchBindingRule(policy, action, req, consentInput = null, round = 1) {
  const binding = policy.binding_v1 || policy;
  if (!binding || !Array.isArray(binding.rules)) return false;

  const transport = (req.transport || 'xhr').toLowerCase();
  const rules = binding.rules.filter(r => {
    if (r.action !== action) return false;
    if (r.transport && r.transport.toLowerCase() !== transport) return false;
    if (req.url && r.url === req.url) return true;
    if (req.path && r.url.endsWith(req.path)) return true;
    return false;
  });
  if (!rules.length) return false;

  for (const rule of rules) {
    // Check headers
    if (rule.headers) {
      if (!req.headers || typeof req.headers !== 'object') return false;
      let headersMatch = true;
      for (const [hk, hv] of Object.entries(rule.headers)) {
        const found = Object.entries(req.headers).find(([k]) => k.toLowerCase() === hk.toLowerCase());
        if (!found || found[1] !== hv) {
          headersMatch = false;
          break;
        }
      }
      if (!headersMatch) continue;
    }

    // If no consent input provided, require at least a non-empty mutation_key
    if (!consentInput) {
      if (typeof req.mutation_key === 'string' && req.mutation_key.length > 0) {
        return true;
      }
      return false;
    }

    if (rule.rows && rule.choices) {
      const rows = consentInput[rule.rows];
      if (!Array.isArray(rows)) continue;
      for (const row of rows) {
        const choices = row[rule.choices];
        if (!Array.isArray(choices)) continue;
        for (const choice of choices) {
          const expectedKey = evaluateKey(rule.key, consentInput, row, choice, round);
          if (expectedKey !== req.mutation_key) continue;

          const expectedForm = evaluateForm(rule.form, consentInput, row, choice);
          if (deepFormMatch(req.form_fields, expectedForm)) {
            return true;
          }
        }
      }
    } else {
      // Actions without rows/choices (e.g. cancel)
      const expectedKey = evaluateKey(rule.key, consentInput, null, null, round);
      if (expectedKey !== req.mutation_key) continue;

      const expectedForm = evaluateForm(rule.form, consentInput, null, null);
      if (deepFormMatch(req.form_fields, expectedForm)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * Convenience wrapper for matchBindingRule against default package HOST_POLICY.
 */
export function isWritePermitted(action, req, consentInput = null, round = 1) {
  return matchBindingRule(HOST_POLICY, action, req, consentInput, round);
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (a == null || b == null) return a === b;
  if (typeof a !== typeof b) return false;
  if (typeof a !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  const aKeys = Object.keys(a).sort();
  const bKeys = Object.keys(b).sort();
  if (aKeys.length !== bKeys.length) return false;
  for (let i = 0; i < aKeys.length; i++) {
    if (aKeys[i] !== bKeys[i]) return false;
    if (!deepEqual(a[aKeys[i]], b[bKeys[i]])) return false;
  }
  return true;
}

function deepFormMatch(actual, expected) {
  if (!actual || !expected) return actual === expected;
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = Object.keys(expected).sort();
  if (actualKeys.length !== expectedKeys.length) return false;
  for (let i = 0; i < actualKeys.length; i++) {
    const k = actualKeys[i];
    if (k !== expectedKeys[i]) return false;
    let actVal = actual[k];
    let expVal = expected[k];
    if (actVal === expVal) continue;
    // Attempt JSON parse comparison
    try {
      const parsedAct = typeof actVal === 'string' && (actVal.trim().startsWith('{') || actVal.trim().startsWith('[')) ? JSON.parse(actVal) : actVal;
      const parsedExp = typeof expVal === 'string' && (expVal.trim().startsWith('{') || expVal.trim().startsWith('[')) ? JSON.parse(expVal) : expVal;
      if (deepEqual(parsedAct, parsedExp)) {
        continue;
      }
    } catch (_) {}
    return false;
  }
  return true;
}

/**
 * Classifies an error or response into write certainty status.
 */
export function evaluateWriteOutcome(errorOrResponse) {
  if (!errorOrResponse) return 'uncertain';
  if (errorOrResponse instanceof Error) {
    if (['NeedsReconciliation', 'LocalTimeout', 'BrowserRequestFailed'].includes(errorOrResponse.code)) {
      return 'uncertain';
    }
    return 'rejected';
  }
  if (typeof errorOrResponse === 'object') {
    if (errorOrResponse.status === 412 || errorOrResponse.status >= 500) {
      return 'uncertain';
    }
    if (errorOrResponse.status === 200) {
      return 'confirmed';
    }
  }
  return 'uncertain';
}
