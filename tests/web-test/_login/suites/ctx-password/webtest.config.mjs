// Password without user in a context — the runner must refuse, not drop it.
export default {
  contexts: { a: { url: 'http://127.0.0.1:9/pub/ru_RU', password: 'secret' } },
};
