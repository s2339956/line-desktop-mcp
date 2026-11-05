export class AutomationError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = 'AutomationError';
    this.code = code;
    this.details = details;
  }
}

export function fail(code, message, details) {
  throw new AutomationError(code, message, details);
}

export function assertPlainObject(value, label = 'args') {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail('INVALID_ARGUMENT', `${label} 必須是物件`, { field: label });
  }
}

export function assertKnownKeys(value, allowed, label = 'args') {
  assertPlainObject(value, label);
  const unknown = Object.keys(value).filter((key) => !allowed.includes(key));
  if (unknown.length > 0) {
    fail('INVALID_ARGUMENT', `${label} 含有未知欄位`, { unknown });
  }
}

export function assertSafeName(value, field) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 200) {
    fail('INVALID_ARGUMENT', `${field} 必須是 1 到 200 字元的字串`, { field });
  }
  // 控制字元與雙向覆寫會讓畫面文字與實際比對值不同，必須在信任邊界拒絕。
  if (/\p{Cc}|[\u202a-\u202e\u2066-\u2069]/u.test(value)) {
    fail('INVALID_ARGUMENT', `${field} 含有不允許的控制或雙向覆寫字元`, { field });
  }
  return value;
}

export function optionalInteger(value, field, minimum, maximum, fallback) {
  if (value === undefined) return fallback;
  if (!Number.isFinite(value) || !Number.isInteger(value) || value < minimum || value > maximum) {
    fail('INVALID_ARGUMENT', `${field} 必須是 ${minimum} 到 ${maximum} 的整數`, { field });
  }
  return value;
}
