import { build } from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const crepeDirectory = path.dirname(require.resolve('@milkdown/crepe/feature/code-mirror'));
const codeMirrorAliases = Object.fromEntries(['@codemirror/view','@codemirror/state'].map(name => [name,require.resolve(name,{paths:[crepeDirectory]})]));
const output = path.resolve(import.meta.dirname, '../Resources/LiveEditor');
await fs.mkdir(output,{recursive:true});
// Milkdown 7.22.3 schedules table selection using an old EditorState. Fast
// typing before that animation frame otherwise dispatches a stale transaction
// and disables the native editor through its error handler. Cancel the stale
// selection only; never swallow real document transactions or editor errors.
const tableSelectionFix = {
  name: 'milkdown-7.22.3-table-selection',
  setup(builder) {
    builder.onLoad({filter:/components\/lib\/table-block\/index\.js$/}, async ({path: file}) => {
      const contents = await fs.readFile(file, 'utf8');
      const before = 'dispatch(state.tr.setSelection(selection).scrollIntoView());';
      if (contents.split(before).length !== 3) throw new Error('Milkdown table patch needs review after dependency update');
      return {contents:contents.replaceAll(before, 'if (view.state.doc === state.doc) dispatch(view.state.tr.setSelection(selection).scrollIntoView());'), loader:'js'};
    });
  },
};
const result = await build({alias:codeMirrorAliases,entryPoints:[path.join(import.meta.dirname,'editor.js')], plugins:[tableSelectionFix], bundle:true, metafile:true, minify:process.env.ASH_EDITOR_DEBUG !== "1", format:'iife', target:'safari17', write:false, outdir:'bundle', legalComments:'eof', loader:{'.woff2':'empty','.woff':'empty','.ttf':'empty'},});
const js = result.outputFiles.find(file=>file.path.endsWith('.js')).text;
const css = result.outputFiles.find(file=>file.path.endsWith('.css')).text;
const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob: file:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'"><style>${css}</style></head><body><input id="document-title" placeholder="无标题笔记" aria-label="笔记标题" hidden><main id="editor"></main><script>${js.replaceAll('</script','<\\/script')}</script></body></html>`;
await fs.writeFile(path.join(output,'editor.html'),html);
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.includes('node_modules/')) continue;
  let directory = path.dirname(path.resolve(input));
  while (directory !== path.dirname(directory)) {
    try {
      const info = JSON.parse(await fs.readFile(path.join(directory,'package.json'),'utf8'));
      if (info.name && info.version) { packages.set(`${info.name}@${info.version}`, {directory,info}); break; }
    } catch {}
    directory = path.dirname(directory);
  }
}
const notices = ['ASH live editor — third-party software notices\nBundled locally; no CDN is required.\n'];
for (const [name,{directory,info}] of [...packages].sort(([a],[b])=>a.localeCompare(b))) {
  const files = (await fs.readdir(directory)).filter(file=>/^licen[cs]e(?:\.|$)/i.test(file));
  notices.push(`\n${'='.repeat(72)}\n${name}\nLicense: ${info.license || 'See included notice'}\n`);
  for (const file of files) notices.push(await fs.readFile(path.join(directory,file),'utf8'));
}
await fs.writeFile(path.join(output,'../ThirdPartyNotices.txt'),notices.join('\n'));
console.log(`Bundled offline editor: ${(Buffer.byteLength(html)/1024/1024).toFixed(2)} MiB`);
