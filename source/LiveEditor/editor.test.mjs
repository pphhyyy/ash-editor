import { webkit, expect } from '@playwright/test';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const browser = await webkit.launch({headless:true});
const page = await browser.newPage({viewport:{width:1000,height:1000}});
const errors = [];
page.on('pageerror', error => errors.push(error.stack || error.message));
await page.addInitScript(() => {
  window.ashMessages = [];
  window.webkit = {messageHandlers:{ashEditor:{postMessage:message=>window.ashMessages.push(message)}}};
});
try {
  await page.goto(pathToFileURL(path.join(import.meta.dirname,'../Resources/LiveEditor/editor.html')).href);
  const source = '# 实时编辑测试\n\n普通正文 **加粗** 和 *斜体*。\n\n| 名称 | 数值 |\n| --- | --- |\n| A | 123 |\n| B | 456 |\n\n```python\nprint("hello")\n```\n\n- [ ] 待办\n- [x] 已完成\n\n> 引用文字\n\n<details><summary>折叠标题</summary>\n\n折叠里的 **正文**\n\n</details>\n\n结尾\n';
  const config = {epoch:1,markdown:source,fontSize:18,ink:'#383047',alignment:'left',concealed:false};
  await page.evaluate(config=>window.ashEditor.configure(config),config);
  await expect(page.locator('.ProseMirror')).toBeVisible();
  await expect(page.locator('h1')).toHaveText('实时编辑测试');
  await expect(page.locator('table tbody tr')).toHaveCount(3);
  await expect(page.locator('.cm-content')).toContainText('print("hello")');
  await expect(page.locator('details summary')).toHaveText('折叠标题');
  assert.equal((await page.evaluate(()=>window.ashEditor.inspect())).markdown,source,'Opening must not normalize or dirty the original source');
  console.log('PASS: headings, bold, table, editable code, tasks, quote, details; opening preserves exact Markdown');

  const cell = page.locator('td').first();
  await cell.click(); await page.keyboard.press('End'); await page.keyboard.insertText('已修改');
  await expect(cell).toContainText('已修改');
  assert.match((await page.evaluate(()=>window.ashEditor.inspect())).markdown,/已修改/);
  console.log('PASS: direct editing inside rendered table cells synchronizes Markdown');

  const code = page.locator('.cm-content').first();
  await code.click(); await page.keyboard.press('End'); await page.keyboard.insertText(' # 直接编辑');
  assert.match((await page.evaluate(()=>window.ashEditor.inspect())).markdown,/直接编辑/);
  console.log('PASS: direct editing in rendered code block synchronizes Markdown');

  await page.evaluate(config=>window.ashEditor.configure({...config,markdown:'stale native echo'}),config);
  assert.match((await page.evaluate(()=>window.ashEditor.inspect())).markdown,/已修改/,'Echo must not reset editor content or caret');
  console.log('PASS: native echo / appearance changes never replace current edits');

  await page.locator('details summary').click({position:{x:4,y:12}});
  await expect(page.locator('details [data-details-body]')).toBeVisible();
  await page.locator('details [data-details-body] p').first().click();
  await page.keyboard.press('End'); await page.keyboard.insertText('继续写');
  assert.match((await page.evaluate(()=>window.ashEditor.inspect())).markdown,/<details[\s\S]*继续写[\s\S]*<\/details>/);
  console.log('PASS: details folds open and content remains directly editable and serializable');

  await page.evaluate(config=>window.ashEditor.configure({...config,epoch:2,markdown:''}),config);
  await page.locator('.ProseMirror').click();
  await page.keyboard.type('# '); await page.keyboard.insertText('输入时变成标题');
  await expect(page.locator('.ProseMirror h1')).toHaveText('输入时变成标题');
  await page.keyboard.press('Enter'); await page.keyboard.insertText('输入中文也能继续');
  assert.match((await page.evaluate(()=>window.ashEditor.inspect())).markdown,/# 输入时变成标题[\s\S]*输入中文也能继续/);
  console.log('PASS: typing Markdown transforms in the SAME editable area, then typing can continue');

  await page.evaluate(config=>window.ashEditor.configure({...config,epoch:2,concealed:true}),config);
  const hidden = await page.locator('.ProseMirror h1').evaluate(node=>getComputedStyle(node).color);
  assert.equal(hidden,'rgba(0, 0, 0, 0)');
  await page.keyboard.insertText('隐藏输入');
  assert.match((await page.evaluate(()=>window.ashEditor.inspect())).markdown,/隐藏输入/);
  console.log('PASS: privacy hides glyphs while preserving editable content');

  const mathSource = '前置说明。\n\n\\[ \\boxed{s_{t+1}=f(s_t,a_t)} \\]\n\n后续说明与行内公式 \\(p(s_t\\mid h_t)\\)。';
  await page.evaluate(config=>window.ashEditor.configure({...config,epoch:3,markdown:'',mathDelimiter:'latex',concealed:false}),config);
  await page.locator('.ProseMirror').evaluate((editable,text)=>{
    const clipboardData = new DataTransfer();
    // Match WebKit's native AppKit pasteboard bridge: plain source is exposed
    // under its UTI name while rich HTML is also present.
    clipboardData.setData('public.utf8-plain-text',text);
    clipboardData.setData('text/html',`<p>${text}</p>`);
    editable.dispatchEvent(new ClipboardEvent('paste',{clipboardData,bubbles:true,cancelable:true}));
  },mathSource);
  await expect(page.locator('.ProseMirror .katex-display')).toHaveCount(1);
  await expect(page.locator('.ProseMirror .katex')).toHaveCount(2);
  const pastedMarkdown = await page.evaluate(()=>window.ashEditor.inspect().markdown);
  assert.match(pastedMarkdown,/\\\[\s*\\boxed\{s_\{t\+1\}=f\(s_t,a_t\)\}\s*\\\]/);
  assert.match(pastedMarkdown,/\\\(p\(s_t\\mid h_t\)\\\)/);
  console.log('PASS: pasted UTI plain text with rich HTML and \\[...\\]/\\(...\\) renders immediately and preserves configured syntax');

  const gptCopiedSource = 'GPT复制内容\n\\\\[ s_t= \\begin{bmatrix} \\text{位置}\\\\ \\text{速度} \\end{bmatrix} \\\\]\n后续说明 \\\\(s_t\\mid h_t\\\\)。';
  await page.evaluate(config=>window.ashEditor.configure({...config,epoch:4,markdown:'',mathDelimiter:'latex'}),config);
  await page.locator('.ProseMirror').evaluate((editable,text)=>{
    const clipboardData = new DataTransfer();
    clipboardData.setData('public.utf8-plain-text',text);
    clipboardData.setData('text/html',`<p>${text}</p>`);
    editable.dispatchEvent(new ClipboardEvent('paste',{clipboardData,bubbles:true,cancelable:true}));
  },gptCopiedSource);
  await expect(page.locator('.ProseMirror .katex-display')).toHaveCount(1);
  await expect(page.locator('.ProseMirror .katex')).toHaveCount(2);
  const gptPastedMarkdown = await page.evaluate(()=>window.ashEditor.inspect().markdown);
  assert.match(gptPastedMarkdown,/\\\[\s*s_t=\s*\\begin\{bmatrix\}/);
  assert.match(gptPastedMarkdown,/\\text\{位置\}\\\\\s*\\text\{速度\}/,'Matrix row breaks keep their two TeX slashes');
  assert.match(gptPastedMarkdown,/\\\(s_t\\mid h_t\\\)/,'Copied inline math delimiters are reduced to one slash');
  console.log('PASS: GPT-style escaped math clipboard renders; paired delimiters normalize while TeX matrix row breaks remain intact');

  await page.evaluate(config=>window.ashEditor.configure({...config,epoch:5,markdown:'',mathDelimiter:'latex'}),config);
  const nativePasteSource = '说明\n\\\\[ s_t=\\begin{bmatrix}\\text{位置}\\\\ \\text{速度}\\end{bmatrix} \\\\]\n后续说明';
  assert.equal(await page.evaluate(source=>window.ashEditor.pasteMarkdown(source),nativePasteSource),true);
  await expect(page.locator('.ProseMirror .katex-display')).toHaveCount(1);
  assert.match((await page.evaluate(()=>window.ashEditor.inspect())).markdown,/\\\[\s*s_t=\\begin\{bmatrix\}/);
  console.log('PASS: native Markdown paste handoff recognizes GPT-style double-backslash delimiters');

  const messages = await page.evaluate(()=>window.ashMessages);
  assert.deepEqual(errors,[]);
  assert.deepEqual(messages.filter(message=>message.type==='error'),[]);
  assert(messages.some(message=>message.type==='change' && message.epoch===2));
  console.log('ALL WEBKIT INTEGRATION CHECKS PASSED');
} catch (error) {
  console.error('Browser errors:', errors, await page.evaluate(()=>window.ashMessages));
  throw error;
} finally { await browser.close(); }
