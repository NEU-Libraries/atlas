// A stranger learns a response faster from one real body than from its
// schema, and a recorded example is checked against that schema by
// oas3-valid-media-example.
export default (responses, _opts, context) => {
  const results = [];
  for (const [status, response] of Object.entries(responses || {})) {
    if (!/^2/.test(status) || !response || response.$ref) continue;
    for (const [type, media] of Object.entries(response.content || {})) {
      if (!/json/.test(type)) continue;
      if (media.example === undefined && media.examples === undefined) {
        results.push({ message: `${status} ${type} has no example.`, path: [...context.path, status, 'content', type] });
      }
    }
  }
  return results;
};
