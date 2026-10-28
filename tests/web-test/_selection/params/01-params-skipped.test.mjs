// Parameterised and skipped: the names are expanded at discovery, no browser needed to see them.
export const name = 'Параметр {случай} / {case}';
export const skip = 'имена разворачиваются без запуска';
export const params = [
  { случай: 'кириллица', case: 'latin' },
  { случай: 'граница_1', case: 'edge' },
];
export default async function () {}
