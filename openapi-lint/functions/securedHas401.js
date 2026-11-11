// Any operation that accepts a credential answers 401 to a bad one, so the
// generated client needs that status in its response union. An operation is
// secured when its effective security names a scheme; `{}` alone is the guest.
const METHODS = ['get', 'put', 'post', 'patch', 'delete', 'head', 'options'];

const secured = (requirements) =>
  (requirements || []).some((req) => Object.keys(req || {}).length > 0);

export default (doc) => {
  const results = [];
  for (const [path, item] of Object.entries(doc.paths || {})) {
    for (const method of METHODS) {
      const op = item && item[method];
      if (!op) continue;
      const security = op.security !== undefined ? op.security : doc.security;
      if (secured(security) && !(op.responses || {})['401']) {
        results.push({ message: `${method.toUpperCase()} ${path} accepts a credential but documents no 401.`, path: ['paths', path, method, 'responses'] });
      }
    }
  }
  return results;
};
