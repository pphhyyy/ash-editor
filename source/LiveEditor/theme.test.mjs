import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import os from 'node:os';
const live=import.meta.dirname;
const output=process.env.ASH_QA_OUTPUT_DIR || await fs.mkdtemp(path.join(os.tmpdir(),'ash-markdown-'));
const require=createRequire(path.join(live,'package.json'));
const {webkit}=require('@playwright/test');
const browser=await webkit.launch({headless:true});
const page=await browser.newPage({viewport:{width:1050,height:1400}});
const errors=[];
page.on('pageerror',e=>errors.push(String(e)));
await page.addInitScript(()=>{
 window.ashMessages=[];window.webkit={messageHandlers:{ashEditor:{postMessage:m=>window.ashMessages.push(m)}}};
});
const fixture='# Markdown 配色检查\n\n正文 **加粗**、*斜体*、~~删除线~~ 和 [链接](https://example.com)。\n\n## 文件与列表\n\n### 三级标题\n\n#### 四级标题\n\n##### 五级标题\n\n###### 六级标题\n\n- `spanning_tree.py`：组合枚举和合法性检查。\n- `matrix_tree.py`：精确拉普拉斯矩阵。\n\n> 引用文字、**强调** 和 `inline_code`。\n\n- [ ] 未完成任务\n- [x] 已完成任务\n\n| 名称 | 内容 |\n| --- | --- |\n| 标准 | 正文 `inline_code` |\n| 高亮 | ==🟣表格里的紫色== |\n\n```python\n# comment\ndef example(value):\n    return "==🟣literal==", 42\n```\n\n==默认黄色== ==🔴红色== ==🟠橙色== ==🟡黄色== ==🟢绿色== ==🔵蓝色== ==🟣紫色==\n\n==🟣包含 **加粗** 和 *斜体*==\n\n`==🟣代码不是高亮==` 和 \\==转义不是高亮==\n\n<details><summary>折叠内容</summary>\n\n==🔵折叠中的蓝色== 和 `code`\n\n</details>\n\n---\n\n末尾正文\n';
const config={epoch:1,markdown:fixture,fontSize:18,ink:'#383047',theme:'紫雾',night:false,alignment:'left',concealed:false,showTitle:true,title:'Markdown 样例',fading:false,fadeOpacity:0.35,fadeDuration:4};
const palettes=[['purple','紫雾',false,'#383047','#fdfcfe'],['paper','纸感',false,'#383047','#fffef9'],['night','夜色',true,'#e0e3e6','#2c2f32']];
try {
 await page.goto(pathToFileURL(path.join(live,'../Resources/LiveEditor/editor.html')).href);
 await page.evaluate(c=>window.ashEditor.configure(c),config);
 await page.waitForSelector('.ProseMirror');
 await page.waitForFunction(()=>window.ashMessages.some(m=>m.type==='ready')||window.ashMessages.some(m=>m.type==='error'));
 const status=await page.evaluate(()=>window.ashMessages);assert(!status.some(m=>m.type==='error'),JSON.stringify(status));
 assert((await page.locator('mark[data-ash-highlight="purple"]').count()) >= 3);
 assert.equal(await page.locator('mark[data-ash-highlight="blue"]').count(),2);
 assert.equal(await page.locator('mark strong,strong mark').count(),1);
 assert(!(await page.locator('mark').allTextContents()).some(s=>s.includes('🟣')));
 assert.equal(await page.locator('code mark,.cm-content mark').count(),0);
 assert((await page.locator('.ProseMirror').innerText()).includes('==转义不是高亮=='));
 const reports=[];
 for(const [name,theme,night,ink,bg] of palettes){
  await page.evaluate(c=>window.ashEditor.configure(c),{...config,theme,night,ink});
  await page.evaluate(bg=>document.body.style.backgroundColor=bg,bg);
  const contrast=await page.evaluate(()=>{
   function rgba(s){const a=s.match(/[\d.]+/g).map(Number);return [...a.slice(0,3),a[3]??1];}
   function over(f,b){return [0,1,2].map(i=>f[i]*f[3]+b[i]*(1-f[3])).concat(1);}
   function background(el){let chain=[];for(let n=el;n;n=n.parentElement)chain.push(n);return chain.reverse().reduce((b,n)=>over(rgba(getComputedStyle(n).backgroundColor),b),[255,255,255,1]);}
   function luminance(c){return c.slice(0,3).map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;}).reduce((a,v,i)=>a+v*[.2126,.7152,.0722][i],0);}
   const selectors=['.ProseMirror h1','.ProseMirror h2','.ProseMirror h3','.ProseMirror h4','.ProseMirror h5','.ProseMirror h6','.ProseMirror strong','.ProseMirror em','.ProseMirror del','.ProseMirror p','.ProseMirror li code','.ProseMirror a','.ProseMirror blockquote p','.ProseMirror th','.ProseMirror td','.cm-content','.cm-gutters','.label-wrapper','.ProseMirror summary',...['red','orange','yellow','green','blue','purple'].map(c=>'mark[data-ash-highlight="'+c+'"]')];
   return selectors.map(selector=>{const el=document.querySelector(selector);if(!el)return {selector,missing:true};const b=background(el),f=over(rgba(getComputedStyle(el).color),b),a=luminance(f),z=luminance(b);return {selector,ratio:(Math.max(a,z)+.05)/(Math.min(a,z)+.05),color:getComputedStyle(el).color,bg:b};});
  });
  for(const c of contrast)assert(!c.missing&&c.ratio>=4.5,`${name}: ${JSON.stringify(c)}`);
  await page.locator('details summary').click();
  await page.screenshot({path:path.join(output,'markdown-'+name+'.png'),fullPage:true});
  reports.push({theme:name,contrast});
  console.log('PASS',name,'contrast >= 4.5 for',contrast.length,'rendered element types');
 }
 await page.locator('.ProseMirror > p').last().click();await page.keyboard.press('End');await page.keyboard.insertText(' edited');
 const serialized=await page.evaluate(()=>window.ashEditor.inspect().markdown);
 assert(serialized.includes('==🟣紫色=='),serialized);
 assert(serialized.includes('==🔵折叠中的蓝色=='),serialized);
 assert(serialized.includes('==🟣包含 **加粗** 和 *斜体*=='),serialized);
 assert(serialized.includes('`==🟣代码不是高亮==`'),serialized);
 console.log('PASS highlight serialization preserves syntax, color prefixes and nested formatting');
 await page.keyboard.press('Enter');await page.keyboard.type('==');await page.keyboard.insertText('🟣');await page.keyboard.type('typed highlight==');
 assert((await page.locator('mark[data-ash-highlight="purple"]').allTextContents()).some(t=>t.includes('typed highlight')));
 console.log('PASS typing closing == applies the purple highlight input rule');
 const before=await page.evaluate(()=>window.ashEditor.inspect().markdown);
 await page.evaluate(c=>window.ashEditor.configure(c),{...config,epoch:2,markdown:before});
 assert((await page.locator('mark[data-ash-highlight="purple"]').allTextContents()).some(t=>t.includes('typed highlight')));
 console.log('PASS saving and reopening keeps highlight colors');
 await page.evaluate(c=>window.ashEditor.configure({...c,readOnly:true}),{...config,epoch:2,markdown:before,theme:'夜色',night:true,ink:'#e0e3e6'});
 assert.equal(await page.locator('.ProseMirror').getAttribute('contenteditable'),'false');
 assert.equal(await page.locator('#document-title').getAttribute('readonly'),'');
 await page.locator('.cm-content').first().click();
 await page.keyboard.insertText('READONLY MUST NOT CHANGE');
 assert.equal(await page.evaluate(()=>window.ashEditor.inspect().markdown),before);
 console.log('PASS shared reading renderer rejects code-block edits');
 assert.deepEqual(errors,[]);assert(!(await page.evaluate(()=>window.ashMessages)).some(m=>m.type==='error'));
 await fs.writeFile(path.join(output,'markdown-theme-report.json'),JSON.stringify(reports,null,2));
 console.log('ALL MARKDOWN THEME AND HIGHLIGHT CHECKS PASSED; artifacts:',output);
} catch(e){console.error(await page.evaluate(()=>window.ashMessages));throw e;} finally{await browser.close();}
