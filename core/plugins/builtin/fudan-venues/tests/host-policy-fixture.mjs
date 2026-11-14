// SPDX-License-Identifier: GPL-3.0-or-later
// Host Policy Binding v1 fixture helper for official.fudan-venues.
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
 */
export function verifyIdentityProbe(expectedAccount, probeSession, probeConfig) {
  if (!expectedAccount || typeof expectedAccount !== 'string') {
    throw fault('InvalidAccount');
  }
  if (!probeSession || probeSession.authenticated !== true) {
    throw fault('AuthenticationRequired');
  }
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
export function evaluateKey(keyTokens, consentInput) {
  const parts = [];
  for (const token of keyTokens) {
    if (typeof token === 'string') {
      parts.push(token);
    } else if (token && typeof token === 'object') {
      if (token.$input) {
        parts.push(String(consentInput[token.$input] ?? ''));
      }
    }
  }
  return parts.join(':');
}

/**
 * Evaluates a form field template against consent input.
 */
export function evaluateFormValue(template, consentInput) {
  if (template === null || template === undefined) return template;
  if (typeof template === 'string') return template;
  if (typeof template === 'number' || typeof template === 'boolean') return template;
  if (Array.isArray(template)) {
    return template.map(item => evaluateFormValue(item, consentInput));
  }
  if (typeof template === 'object') {
    if (template.$text) return String(evaluateFormValue(template.$text, consentInput));
    if (template.$input) {
      return consentInput[template.$input];
    }
    if (template.$json !== undefined) {
      const evaluated = evaluateFormValue(template.$json, consentInput);
      return JSON.stringify(evaluated);
    }
    const result = {};
    for (const [k, v] of Object.entries(template)) {
      result[k] = evaluateFormValue(v, consentInput);
    }
    return result;
  }
  return template;
}

export function evaluateForm(formTemplate, consentInput) {
  const result = {};
  for (const [key, tpl] of Object.entries(formTemplate)) {
    const val = evaluateFormValue(tpl, consentInput);
    result[key] = typeof val === 'object' && val !== null ? JSON.stringify(val) : String(val);
  }
  return result;
}

export function deepFormMatch(actual, expected) {
  if (!actual || !expected) return false;
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = Object.keys(expected).sort();
  if (actualKeys.length !== expectedKeys.length) return false;
  for (let i = 0; i < actualKeys.length; i++) {
    if (actualKeys[i] !== expectedKeys[i]) return false;
  }
  for (const k of actualKeys) {
    const act = actual[k];
    const exp = expected[k];
    if (act === exp) continue;
    try {
      const parsedAct = JSON.parse(act);
      const parsedExp = JSON.parse(exp);
      if (JSON.stringify(parsedAct) !== JSON.stringify(parsedExp)) return false;
    } catch {
      return false;
    }
  }
  return true;
}

export function matchBindingRule(policy, action, req, consentInput = null) {
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

    if (!consentInput) {
      if (typeof req.mutation_key === 'string' && req.mutation_key.length > 0) {
        return true;
      }
      return false;
    }

    const expectedKey = evaluateKey(rule.key, consentInput);
    if (expectedKey !== req.mutation_key) continue;

    const expectedForm = evaluateForm(rule.form, consentInput);
    if (deepFormMatch(req.form_fields, expectedForm)) {
      return true;
    }
  }
  return false;
}
