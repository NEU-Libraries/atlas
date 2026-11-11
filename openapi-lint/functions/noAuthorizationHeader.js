// A hand-written Authorization parameter duplicates the security scheme, and a
// generated client then asks for the token twice, in two different places.
const METHODS = ['get', 'put', 'post', 'patch', 'delete', 'head', 'options'];

const offending = (params) =>
  (params || []).filter((p) => p && p.in === 'header' && /^authorization$/i.test(p.name || ''));

export default (item, _opts, context) => {
  const results = [];
  offending(item.parameters).forEach(() =>
    results.push({ message: 'Path declares Authorization as a header parameter.', path: [...context.path, 'parameters'] }));
  for (const method of METHODS) {
    if (!item[method]) continue;
    offending(item[method].parameters).forEach(() =>
      results.push({ message: `${method.toUpperCase()} declares Authorization as a header parameter.`, path: [...context.path, method, 'parameters'] }));
  }
  return results;
};
