// Every 4xx body is the shared Error shape, so a client can branch on `error`
// for any failure. A 4xx with no content passes: Atlas answers some 404s with
// no body at all, and the document must not invent one. A 410 can instead
// carry the tombstoned resource's own record or a stub of it, named by
// component $refs.
const ERROR_REF = '#/components/schemas/Error';
const isComponentRef = (schema) =>
  !!schema && typeof schema.$ref === 'string' && schema.$ref.startsWith('#/components/schemas/');
const isTombstoneRecord = (status, schema) =>
  status === '410' && !!schema && (isComponentRef(schema) || (schema.oneOf || []).every(isComponentRef) && !!schema.oneOf);

const refersToError = (schema) =>
  !!schema && (schema.$ref === ERROR_REF ||
    (schema.allOf || []).some((part) => part.$ref === ERROR_REF));

export default (responses, _opts, context) => {
  const results = [];
  for (const [status, response] of Object.entries(responses || {})) {
    if (!/^4/.test(status) || !response || response.$ref) continue;
    for (const [type, media] of Object.entries(response.content || {})) {
      if (!/json/.test(type)) {
        results.push({ message: `${status} body is ${type}; an error body is application/json.`, path: [...context.path, status, 'content', type] });
      } else if (!refersToError(media.schema) && !isTombstoneRecord(status, media.schema)) {
        results.push({ message: `${status} body does not reference ${ERROR_REF}.`, path: [...context.path, status, 'content', type] });
      }
    }
  }
  return results;
};
