import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, unlink, writeFile } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import process from 'node:process';
import puppeteer from 'puppeteer';
import { createCanvas, loadImage } from '@napi-rs/canvas';

const WIDTH = 3840;
const HEIGHT = 2160;
const root = resolve(process.cwd());
const diagramDir = join(root, 'docs', 'diagrams');
const assetDir = join(diagramDir, 'assets', 'azure');
const outputDir = join(diagramDir, 'rendered');
const lockPath = join(diagramDir, 'approved-contract-lock.json');
const browserPath = process.argv[2] || process.env.PUPPETEER_EXECUTABLE_PATH;

if (!browserPath) {
  throw new Error('A Chromium executable path is required. Use Render-ApprovedDiagrams.ps1.');
}

const sha256 = (content) => createHash('sha256').update(content).digest('hex');
const esc = (value) => String(value)
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;');

const lock = JSON.parse(await readFile(lockPath, 'utf8'));
const iconCache = new Map();

async function iconData(name) {
  if (!name) return null;
  if (!iconCache.has(name)) {
    const bytes = await readFile(join(assetDir, name));
    iconCache.set(name, `data:image/svg+xml;base64,${bytes.toString('base64')}`);
  }
  return iconCache.get(name);
}

function boundary({ id, x, y, w, h, title, subtitle = '', tone = 'neutral' }) {
  return `<section class="boundary tone-${tone}" data-boundary-id="${esc(id)}" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px">
    <div class="boundary-title">${esc(title)}</div>
    ${subtitle ? `<div class="boundary-subtitle">${esc(subtitle)}</div>` : ''}
  </section>`;
}

async function card({
  id, x, y, w, h, title, subtitle = '', eyebrow = '', icon = null, icons = [],
  tone = 'azure', symbol = '', compact = false, align = 'left'
}) {
  const iconNames = icon ? [icon] : icons;
  const iconMarkup = iconNames.length
    ? `<div class="icon-stack">${(await Promise.all(iconNames.map(async (name) => `<img src="${await iconData(name)}" alt=""/>`))).join('')}</div>`
    : symbol ? `<div class="symbol">${esc(symbol)}</div>` : '';
  return `<article class="card tone-${tone}${compact ? ' compact' : ''} align-${align}" data-node-id="${esc(id)}" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px">
    ${iconMarkup}
    <div class="card-copy">
      ${eyebrow ? `<div class="eyebrow">${esc(eyebrow)}</div>` : ''}
      <div class="card-title">${esc(title)}</div>
      ${subtitle ? `<div class="card-subtitle">${esc(subtitle)}</div>` : ''}
    </div>
  </article>`;
}

function edge({ id, points, label = '', lx = 0, ly = 0, lw = 280, dashed = false, tone = 'neutral', arrow = true }) {
  const pointText = points.map(([x, y]) => `${x},${y}`).join(' ');
  return {
    svg: `<polyline data-edge-id="${esc(id)}" points="${pointText}" class="edge tone-${tone}${dashed ? ' dashed' : ''}" ${arrow ? `marker-end="url(#arrow-${tone})"` : ''}/>` ,
    label: label ? `<div class="edge-label tone-${tone}" style="left:${lx}px;top:${ly}px;width:${lw}px">${esc(label)}</div>` : ''
  };
}

function note({ x, y, w, h, title, text, tone = 'amber' }) {
  return `<aside class="note tone-${tone}" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px">
    <div class="note-title">${esc(title)}</div><div class="note-text">${esc(text)}</div>
  </aside>`;
}

function sequenceNumber(number, x, y, tone = 'navy') {
  return `<div class="sequence-number tone-${tone}" style="left:${x - 25}px;top:${y - 25}px">${number}</div>`;
}

function diagramShell({ title, subtitle, kicker, body, edges, labels, hash }) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    *{box-sizing:border-box} html,body{margin:0;width:${WIDTH}px;height:${HEIGHT}px;overflow:hidden;background:#fff}
    body{font-family:Aptos,'Segoe UI',sans-serif;color:#172b4d}
    .canvas{position:relative;width:${WIDTH}px;height:${HEIGHT}px;background:#fff;overflow:hidden}
    .kicker{position:absolute;left:120px;top:70px;font-size:25px;line-height:1;color:#0067b8;font-weight:700;text-transform:uppercase;letter-spacing:1.6px;z-index:9}
    h1{position:absolute;left:120px;top:116px;margin:0;font-size:66px;line-height:1.06;font-weight:650;letter-spacing:0;z-index:9}
    .subtitle{position:absolute;left:124px;top:205px;width:3300px;margin:0;font-size:29px;line-height:1.35;color:#4b5f73;z-index:9}
    .boundary{position:absolute;border:2px solid #9aa9b8;background:#f8fafc;z-index:1;border-radius:8px}
    .boundary.tone-blue{border-color:#4f87c5;background:#f4f8fd}.boundary.tone-green{border-color:#58a56c;background:#f5fbf6}.boundary.tone-amber{border-color:#c58a20;background:#fffaf0}
    .boundary-title{position:absolute;left:24px;top:16px;font-size:29px;font-weight:650;color:#25384a;background:inherit;padding-right:10px}
    .boundary-subtitle{position:absolute;left:24px;top:54px;font-size:21px;color:#5b6b79}
    .connectors{position:absolute;inset:0;width:${WIDTH}px;height:${HEIGHT}px;z-index:2;pointer-events:none;overflow:visible}
    .edge{fill:none;stroke:#52687b;stroke-width:4;stroke-linejoin:round;stroke-linecap:round}.edge.dashed{stroke-dasharray:14 11}.edge.tone-blue{stroke:#0078d4}.edge.tone-green{stroke:#258744}.edge.tone-red{stroke:#c42b1c}.edge.tone-amber{stroke:#b56a00}.edge.tone-neutral{stroke:#52687b}
    .card{position:absolute;display:flex;align-items:center;gap:24px;padding:26px 30px;border:2px solid #7b91a6;background:#fff;z-index:4;border-radius:8px;box-shadow:0 8px 22px rgba(23,43,77,.09)}
    .card.compact{padding:18px 22px;gap:17px}.card.align-center{justify-content:center;text-align:center}.card.align-center .card-copy{align-items:center}
    .card.tone-azure{border-color:#3b82c4;background:#f2f7fc}.card.tone-green{border-color:#3b9255;background:#f1faf3}.card.tone-red{border-color:#d44b43;background:#fff4f3}.card.tone-amber{border-color:#c58a20;background:#fff8e8}.card.tone-navy{border-color:#335b7c;background:#eef3f7}.card.tone-neutral{border-color:#8b9aaa;background:#fff}
    .icon-stack{display:flex;flex:0 0 auto;align-items:center;gap:10px}.icon-stack img{width:72px;height:72px;object-fit:contain}.compact .icon-stack img{width:56px;height:56px}.icon-stack img+img{margin-left:-4px}
    .symbol{display:flex;align-items:center;justify-content:center;flex:0 0 auto;width:66px;height:66px;border-radius:50%;background:#dcecf9;color:#005a9e;font-size:22px;font-weight:750}.compact .symbol{width:50px;height:50px;font-size:17px}
    .card-copy{display:flex;min-width:0;flex-direction:column;justify-content:center;gap:7px}.eyebrow{font-size:19px;line-height:1;color:#0067b8;font-weight:750;text-transform:uppercase;letter-spacing:1px}.card-title{font-size:31px;line-height:1.15;font-weight:650;letter-spacing:0}.compact .card-title{font-size:26px}.card-subtitle{font-size:23px;line-height:1.32;color:#526273}.compact .card-subtitle{font-size:20px}
    .edge-label{position:absolute;z-index:5;padding:7px 12px;background:rgba(255,255,255,.96);font-size:22px;line-height:1.18;text-align:center;color:#334b60;border-radius:4px}.edge-label.tone-green{color:#166b32}.edge-label.tone-red{color:#a4262c}.edge-label.tone-blue{color:#005a9e}.edge-label.tone-amber{color:#8c5200}
    .note{position:absolute;z-index:5;padding:22px 28px;border:2px solid #c58a20;background:#fff8e8;border-radius:8px}.note.tone-green{border-color:#3b9255;background:#f1faf3}.note.tone-red{border-color:#d44b43;background:#fff4f3}.note-title{font-size:24px;font-weight:700;margin-bottom:7px}.note-text{font-size:21px;line-height:1.3;color:#495b6c}
    .sequence-number{position:absolute;z-index:6;width:50px;height:50px;border-radius:50%;display:flex;align-items:center;justify-content:center;color:#fff;background:#172b4d;font-size:21px;font-weight:750}.sequence-number.tone-green{background:#258744}.sequence-number.tone-red{background:#c42b1c}
    .footer{position:absolute;left:120px;right:120px;bottom:50px;border-top:2px solid #d8e0e8;padding-top:20px;display:flex;justify-content:space-between;font-size:20px;color:#637587;z-index:9}
    .legend{position:absolute;z-index:6;display:flex;gap:28px;align-items:center;font-size:21px;color:#455b6d}.legend-item{display:flex;gap:10px;align-items:center}.legend-line{width:54px;border-top:4px solid #52687b}.legend-line.dashed{border-top-style:dashed}.legend-swatch{width:24px;height:24px;border-radius:4px;border:2px solid}.legend-swatch.green{background:#f1faf3;border-color:#3b9255}.legend-swatch.red{background:#fff4f3;border-color:#d44b43}
  </style></head><body><main class="canvas">
    <div class="kicker">${esc(kicker)}</div><h1>${esc(title)}</h1><p class="subtitle">${esc(subtitle)}</p>
    ${body}
    <svg class="connectors" viewBox="0 0 ${WIDTH} ${HEIGHT}" aria-hidden="true"><defs>
      ${['neutral','blue','green','red','amber'].map((tone) => { const colors={neutral:'#52687b',blue:'#0078d4',green:'#258744',red:'#c42b1c',amber:'#b56a00'}; return `<marker id="arrow-${tone}" markerWidth="13" markerHeight="13" refX="10" refY="5" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L10,5 L0,10 z" fill="${colors[tone]}"/></marker>`; }).join('')}
    </defs>${edges}</svg>${labels}
    <footer class="footer"><span>Rendered from the human-approved Mermaid contract</span><span>Source SHA-256: ${hash.slice(0,16)}…</span></footer>
  </main></body></html>`;
}

async function validationLab(hash) {
  const cards = [];
  const edges = [];
  cards.push(boundary({id:'rg',x:430,y:330,w:3280,h:1660,title:'Azure resource group',subtitle:'Validation lab - shared backing services',tone:'neutral'}));
  cards.push(boundary({id:'foundry',x:560,y:490,w:1260,h:1280,title:'Microsoft Foundry account',subtitle:'Centralized account governance',tone:'blue'}));
  cards.push(boundary({id:'backing',x:1980,y:490,w:1050,h:1280,title:'Connected Azure resources',subtitle:'Independently governed service boundaries',tone:'amber'}));
  cards.push(await card({id:'reviewer',x:90,y:900,w:300,h:170,title:'Security reviewer',subtitle:'Deploys lab and runs probes',symbol:'USER',tone:'neutral',compact:true,align:'center'}));
  cards.push(await card({id:'account',x:800,y:650,w:790,h:220,title:'Account governance',subtitle:'Shared model deployment',icons:['microsoft-foundry.svg','foundry-models.svg'],tone:'azure'}));
  cards.push(await card({id:'alpha',x:710,y:1040,w:880,h:250,title:'Project alpha',subtitle:'Managed identity, connections, agent runtime and capability host',icons:['foundry-project.svg','managed-identity.svg'],tone:'azure'}));
  cards.push(await card({id:'bravo',x:710,y:1400,w:880,h:250,title:'Project bravo',subtitle:'Managed identity, connections, agent runtime and capability host',icons:['foundry-project.svg','managed-identity.svg'],tone:'green'}));
  cards.push(await card({id:'cosmos',x:2140,y:650,w:720,h:190,title:'Azure Cosmos DB',subtitle:'Shared enterprise_memory database',icon:'cosmos-db.svg',tone:'amber'}));
  cards.push(await card({id:'storage',x:2140,y:930,w:720,h:190,title:'Azure Storage',subtitle:'Shared account',icon:'storage-account.svg',tone:'amber'}));
  cards.push(await card({id:'search',x:2140,y:1210,w:720,h:190,title:'Azure AI Search',subtitle:'Shared service',icon:'ai-search.svg',tone:'amber'}));
  cards.push(await card({id:'key_vault',x:2140,y:1490,w:720,h:190,title:'Azure Key Vault',subtitle:'Reference dependency; not on measured data path',icon:'key-vault.svg',tone:'neutral'}));
  cards.push(await card({id:'monitor',x:3170,y:930,w:430,h:330,title:'Diagnostics and telemetry',subtitle:'Application Insights and Log Analytics',icons:['application-insights.svg','log-analytics.svg'],tone:'azure',align:'center'}));

  edges.push(edge({id:'reviewer->account',points:[[390,985],[600,985],[600,760],[800,760]],label:'Deploys lab and runs probes',lx:410,ly:865,lw:330,tone:'blue'}));
  edges.push(edge({id:'account->alpha',points:[[1195,870],[1195,1040]],tone:'blue'}));
  edges.push(edge({id:'account->bravo',points:[[1040,870],[1040,960],[560,960],[560,1525],[710,1525]],tone:'blue'}));
  const serviceYs=[745,1025,1305];
  const labels=['Conversation and agent state','Files','Vector data'];
  const targets=['cosmos','storage','search'];
  for(let i=0;i<3;i++){
    edges.push(edge({id:`alpha->${targets[i]}`,points:[[1590,1110+i*45],[1870,1110+i*45],[1870,serviceYs[i]],[2140,serviceYs[i]]],label:labels[i],lx:1700,ly:serviceYs[i]-55,lw:360,tone:'blue'}));
    edges.push(edge({id:`bravo->${targets[i]}`,points:[[1590,1485+i*45],[1930,1485+i*45],[1930,serviceYs[i]+55],[2140,serviceYs[i]+55]],label:labels[i],lx:1700,ly:serviceYs[i]+65,lw:360,tone:'green'}));
  }
  edges.push(edge({id:'cosmos->monitor',points:[[2860,745],[3100,745],[3100,1015],[3170,1015]],label:'DataPlaneRequests',lx:2860,ly:790,lw:260,dashed:true,tone:'neutral'}));
  edges.push(edge({id:'storage->monitor',points:[[2860,1025],[3170,1025]],label:'Storage read/write logs',lx:2865,ly:1065,lw:280,dashed:true,tone:'neutral'}));
  return diagramShell({title:'Validation lab topology',subtitle:'Two Foundry projects intentionally share Cosmos DB, Storage, and AI Search so permission boundaries can be measured.',kicker:'Microsoft Foundry · Security validation',body:cards.join(''),edges:edges.map(e=>e.svg).join(''),labels:edges.map(e=>e.label).join(''),hash});
}

async function measuredBoundary(hash) {
  const body=[]; const edges=[];
  const lanes=[
    {id:'cosmos_lane',x:110,title:'Azure Cosmos DB',icon:'cosmos-db.svg'},
    {id:'storage_lane',x:1305,title:'Azure Storage',icon:'storage-account.svg'},
    {id:'search_lane',x:2500,title:'Azure AI Search',icon:'ai-search.svg'}
  ];
  for(const lane of lanes){
    body.push(boundary({id:lane.id,x:lane.x,y:500,w:1120,h:1400,title:lane.title,subtitle:'Broad scope compared with project-constrained scope',tone:'neutral'}));
    body.push(await card({id:`${lane.id}_service`,x:lane.x+760,y:535,w:280,h:110,title:lane.title,icon:lane.icon,tone:'neutral',compact:true}));
  }
  body.push(note({x:1080,y:310,w:1680,h:120,title:'Scope',text:'Direct data-plane authorization. Persistent provisioning and management roles are assessed separately.',tone:'amber'}));
  body.push(`<div class="legend" style="left:2450px;top:380px"><div class="legend-item"><span class="legend-swatch red"></span>Cross-project reach</div><div class="legend-item"><span class="legend-swatch green"></span>Project-constrained control</div><div class="legend-item"><span class="legend-line dashed"></span>Denied / secondary</div></div>`);

  const configs=[
    {prefix:'cosmos',x:110,broad:'Database-scoped role',constrained:'Alpha container-scoped roles',targets:['Alpha containers','Bravo containers'],icon:'cosmos-db.svg',constraint:null},
    {prefix:'storage',x:1305,broad:'Unconditioned account role',broadSub:'Connectivity control',constrained:'Account role with alpha container-prefix condition',targets:['Alpha containers','Bravo containers'],icon:'storage-account.svg',constraint:null},
    {prefix:'search',x:2500,broad:'Service-scoped role',constrained:'Index-scoped role',targets:['Selected index','Other index'],icon:'ai-search.svg',constraint:'Foundry index names do not identify a project'}
  ];
  for(const cfg of configs){
    const left=cfg.x+70,right=cfg.x+705;
    body.push(await card({id:`${cfg.prefix}_${cfg.prefix==='cosmos'?'database':cfg.prefix==='storage'?'account':'service'}`,x:left,y:760,w:470,h:190,title:cfg.broad,subtitle:cfg.broadSub||'Broad scope',symbol:'RBAC',tone:'azure'}));
    body.push(await card({id:`${cfg.prefix}_alpha`,x:right,y:720,w:330,h:135,title:cfg.targets[0],tone:'azure',compact:true,align:'center'}));
    body.push(await card({id:`${cfg.prefix}_bravo`,x:right,y:925,w:330,h:135,title:cfg.targets[1],tone:'red',compact:true,align:'center'}));
    body.push(await card({id:`${cfg.prefix}_${cfg.prefix==='cosmos'?'container':cfg.prefix==='storage'?'abac':'index'}`,x:left,y:1240,w:470,h:220,title:cfg.constrained,subtitle:'Project-constrained',symbol:'RBAC',tone:'green'}));
    body.push(await card({id:`${cfg.prefix}_alpha_h`,x:right,y:1210,w:330,h:135,title:cfg.targets[0],tone:'green',compact:true,align:'center'}));
    body.push(await card({id:`${cfg.prefix}_bravo_h`,x:right,y:1445,w:330,h:135,title:cfg.targets[1],tone:'neutral',compact:true,align:'center'}));
    edges.push(edge({id:`${cfg.prefix}-broad-own`,points:[[left+470,815],[right,787]],label:'ALLOW',lx:left+475,ly:740,lw:210,tone:'blue'}));
    edges.push(edge({id:`${cfg.prefix}-broad-cross`,points:[[left+470,895],[right,992]],label:'ALLOW cross-project',lx:left+475,ly:900,lw:250,tone:'red'}));
    const ownLabel=cfg.prefix==='search'?'ALLOW selected index':'ALLOW own project';
    const denyLabel=cfg.prefix==='search'?'DENY other index':'DENY cross-project';
    edges.push(edge({id:`${cfg.prefix}-constrained-own`,points:[[left+470,1300],[right,1277]],label:ownLabel,lx:left+460,ly:1225,lw:255,tone:'green'}));
    edges.push(edge({id:`${cfg.prefix}-constrained-cross`,points:[[left+470,1410],[right,1512]],label:denyLabel,lx:left+465,ly:1440,lw:245,dashed:true,tone:'neutral'}));
    if(cfg.constraint){
      body.push(note({x:cfg.x+250,y:1660,w:620,h:160,title:'Operational constraint',text:cfg.constraint,tone:'amber'}));
      edges.push(edge({id:'search-index->opaque',points:[[left+250,1460],[left+250,1610],[cfg.x+560,1610],[cfg.x+560,1660]],dashed:true,tone:'amber'}));
    }
  }
  return diagramShell({title:'Measured authorization boundary',subtitle:'Each lane compares broad reach with the project-constrained control measured against the same backing service.',kicker:'Microsoft Foundry · Authorization findings',body:body.join(''),edges:edges.map(e=>e.svg).join(''),labels:edges.map(e=>e.label).join(''),hash});
}

async function targetState(hash) {
  const body=[]; const edges=[];
  body.push(boundary({id:'foundry',x:140,y:420,w:1450,h:1480,title:'Microsoft Foundry account',subtitle:'Centralized governance and approved model deployments',tone:'blue'}));
  body.push(boundary({id:'alpha_boundary',x:1900,y:420,w:1780,h:650,title:'Alpha data trust boundary',subtitle:'Backing resources owned by project alpha',tone:'blue'}));
  body.push(boundary({id:'bravo_boundary',x:1900,y:1190,w:1780,h:650,title:'Bravo data trust boundary',subtitle:'Backing resources owned by project bravo',tone:'green'}));
  body.push(await card({id:'shared_model',x:310,y:620,w:690,h:220,title:'Approved model deployments',subtitle:'Shared through Foundry account governance',icons:['microsoft-foundry.svg','foundry-models.svg'],tone:'azure'}));
  body.push(await card({id:'alpha_project',x:760,y:960,w:670,h:200,title:'Project alpha',subtitle:'Project managed identity',icons:['foundry-project.svg','managed-identity.svg'],tone:'azure'}));
  body.push(await card({id:'bravo_project',x:760,y:1400,w:670,h:200,title:'Project bravo',subtitle:'Project managed identity',icons:['foundry-project.svg','managed-identity.svg'],tone:'green'}));
  const alphaServices=[['alpha_cosmos','Azure Cosmos DB','cosmos-db.svg'],['alpha_storage','Azure Storage','storage-account.svg'],['alpha_search','Azure AI Search','ai-search.svg']];
  const bravoServices=[['bravo_cosmos','Azure Cosmos DB','cosmos-db.svg'],['bravo_storage','Azure Storage','storage-account.svg'],['bravo_search','Azure AI Search','ai-search.svg']];
  const xs=[2070,2580,3090];
  for(let i=0;i<3;i++){
    body.push(await card({id:alphaServices[i][0],x:xs[i],y:660,w:420,h:190,title:alphaServices[i][1],subtitle:'Dedicated to alpha',icon:alphaServices[i][2],tone:'azure',compact:true}));
    body.push(await card({id:bravoServices[i][0],x:xs[i],y:1430,w:420,h:190,title:bravoServices[i][1],subtitle:'Dedicated to bravo',icon:bravoServices[i][2],tone:'green',compact:true}));
  }
  edges.push(edge({id:'alpha_project->alpha_cosmos',points:[[1430,1010],[1740,1010],[1740,755],[2070,755]],label:'Project identity only',lx:1640,ly:820,lw:260,tone:'blue'}));
  edges.push(edge({id:'alpha_project->alpha_storage',points:[[1430,1060],[1780,1060],[1780,570],[2790,570],[2790,660]],label:'Project identity only',lx:2490,ly:535,lw:260,tone:'blue'}));
  edges.push(edge({id:'alpha_project->alpha_search',points:[[1430,1110],[1820,1110],[1820,620],[3300,620],[3300,660]],label:'Project identity only',lx:3150,ly:585,lw:260,tone:'blue'}));
  edges.push(edge({id:'bravo_project->bravo_cosmos',points:[[1430,1460],[1740,1460],[1740,1525],[2070,1525]],label:'Project identity only',lx:1640,ly:1480,lw:260,tone:'green'}));
  edges.push(edge({id:'bravo_project->bravo_storage',points:[[1430,1510],[1780,1510],[1780,1710],[2790,1710],[2790,1620]],label:'Project identity only',lx:2490,ly:1675,lw:260,tone:'green'}));
  edges.push(edge({id:'bravo_project->bravo_search',points:[[1430,1560],[1820,1560],[1820,1765],[3300,1765],[3300,1620]],label:'Project identity only',lx:3150,ly:1730,lw:260,tone:'green'}));
  edges.push(edge({id:'shared_model->alpha_project',points:[[830,840],[830,960]],tone:'blue'}));
  edges.push(edge({id:'shared_model->bravo_project',points:[[650,840],[650,1500],[760,1500]],tone:'green'}));
  body.push(note({x:1990,y:1075,w:1590,h:110,title:'No shared backing service across trust boundaries',text:'Service-scoped permissions remain contained within the owning project resource set.',tone:'amber'}));
  return diagramShell({title:'Recommended customer target state',subtitle:'Keep Foundry governance centralized where appropriate, but align each data-service boundary to the project trust boundary.',kicker:'Microsoft Foundry · Target architecture',body:body.join(''),edges:edges.map(e=>e.svg).join(''),labels:edges.map(e=>e.label).join(''),hash});
}

async function sequence(hash) {
  const body=[]; const edges=[]; const labels=[];
  const participants=[
    {id:'deployment_automation',x:220,title:'Deployment automation',symbol:'IaC',tone:'navy'},
    {id:'foundry_project',x:920,title:'Foundry project',icon:'foundry-project.svg',tone:'azure'},
    {id:'shared_cosmos',x:1660,title:'Shared Cosmos DB',icon:'cosmos-db.svg',tone:'amber'},
    {id:'shared_storage',x:2400,title:'Shared Storage',icon:'storage-account.svg',tone:'amber'},
    {id:'verification_gate',x:3220,title:'Verification gate',symbol:'GATE',tone:'green'}
  ];
  for(const p of participants){
    body.push(await card({id:p.id,x:p.x,y:320,w:400,h:145,title:p.title,icon:p.icon,symbol:p.symbol,tone:p.tone,compact:true,align:'center'}));
    edges.push(`<line x1="${p.x+200}" y1="465" x2="${p.x+200}" y2="2010" stroke="#8aa0b4" stroke-width="3" stroke-dasharray="10 10"/>`);
  }
  const x={d:420,f:1120,c:1860,s:2600,g:3420};
  const messages=[
    [1,x.d,x.f,550,'Create project, identity, connections, capability host','blue'],
    [2,x.d,x.c,660,'Grant temporary database-scoped access','amber'],
    [3,x.d,x.s,770,'Grant account role with project-prefix condition','amber'],
    [4,x.d,x.f,980,'Invoke one canary agent through Responses API','blue'],
    [5,x.f,x.c,1090,'Create the two lazy modern containers','blue'],
    [6,x.f,x.s,1200,'Create project-prefixed containers','blue'],
    [7,x.d,x.c,1310,'Add five project-container grants','green'],
    [8,x.d,x.c,1420,'Remove temporary database grant','green'],
    [9,x.d,x.g,1530,'Inventory actual grants and container ownership','neutral'],
    [10,x.g,x.c,1640,'Own-project ALLOW and cross-project DENY','green'],
    [11,x.g,x.s,1745,'Own-project ALLOW and cross-project DENY','green']
  ];
  for(const [n,from,to,y,text,tone] of messages){
    const dir=from<to?1:-1;
    const labelX=Math.min(from,to)+Math.abs(to-from)/2-260;
    body.push(sequenceNumber(n,from,y,tone==='green'?'green':'navy'));
    const e=edge({id:`message-${n}`,points:[[from,y],[to,y]],label:text,lx:labelX,ly:y-55,lw:520,tone});
    edges.push(e.svg); labels.push(e.label);
  }
  body.push(note({x:640,y:820,w:1900,h:105,title:'Bootstrap window',text:'Synthetic data only. No user or workload access.',tone:'amber'}));
  body.push(`<section class="boundary tone-green" data-boundary-id="verification_alt" style="left:160px;top:1805px;width:3520px;height:260px"><div class="boundary-title">Verification decision</div></section>`);
  body.push(`<div style="position:absolute;left:180px;top:1930px;width:3480px;border-top:2px dashed #8aa0b4;z-index:3"></div>`);
  body.push(sequenceNumber(12,x.g,1880,'green'));
  let e=edge({id:'message-12',points:[[x.g,1880],[x.d,1880]],label:'Cosmos and Storage verified · user access may now be assigned',lx:1430,ly:1825,lw:1000,dashed:true,tone:'green'});edges.push(e.svg);labels.push(e.label);
  body.push(sequenceNumber(13,x.g,2000,'red'));
  e=edge({id:'message-13',points:[[x.g,2000],[x.d,2000]],label:'Fail closed · environment remains unavailable for real data',lx:1430,ly:1945,lw:1000,dashed:true,tone:'red'});edges.push(e.svg);labels.push(e.label);
  return diagramShell({title:'Bootstrap, harden, and verify',subtitle:'The shared-Cosmos bootstrap window closes only after the real project grants and live Cosmos/Blob controls both pass.',kicker:'Microsoft Foundry · Controlled deployment sequence',body:body.join(''),edges:edges.join(''),labels:labels.join(''),hash});
}

async function evidenceFlow(hash) {
  const body=[]; const edges=[];
  body.push(boundary({id:'controls',x:100,y:430,w:820,h:1430,title:'1 · Test controls',subtitle:'Create attributable, discriminating inputs',tone:'amber'}));
  body.push(boundary({id:'artifacts',x:1010,y:430,w:900,h:1430,title:'2 · Structured evidence',subtitle:'Record facts before interpretation',tone:'blue'}));
  body.push(boundary({id:'assurance',x:2010,y:430,w:760,h:1430,title:'3 · Assurance record',subtitle:'Bind provenance and enforce the contract',tone:'neutral'}));
  body.push(boundary({id:'review',x:2870,y:430,w:870,h:1430,title:'4 · Human review',subtitle:'Only validated evidence supports findings',tone:'green'}));

  const controlDefs=[
    ['canary',600,'Project canary agents','Distinct response per project','foundry-agent-service.svg'],
    ['deployer',820,'Deployer control','Resources exist and are attributable',null],
    ['broad',1040,'Broad connectivity control','Alpha ALLOW · Bravo ALLOW',null],
    ['alpha_probe',1260,'Alpha-scoped probe','Alpha ALLOW · Bravo DENY',null],
    ['bravo_probe',1480,'Bravo-scoped probe','Alpha DENY · Bravo ALLOW',null],
    ['search_probe',1700,'Serialized vector-store creation','Exactly one new index per project','ai-search.svg']
  ];
  for(const [id,y,title,subtitle,icon] of controlDefs){body.push(await card({id,x:190,y,w:640,h:150,title,subtitle,icon,symbol:icon?null:'TEST',tone:'amber',compact:true}));}
  const artifactDefs=[
    ['agents',610,'Agent evidence','API, identity, canary'],
    ['inventory',850,'Inventory evidence','Resources and actual grants'],
    ['broad_result',1050,'Broad outcome','Alpha ALLOW · Bravo ALLOW'],
    ['alpha_result',1220,'Alpha-scoped outcome','Alpha ALLOW · Bravo DENY'],
    ['bravo_result',1390,'Bravo-scoped outcome','Alpha DENY · Bravo ALLOW'],
    ['matrix',1570,'Access matrix evidence','Cosmos and Blob outcomes'],
    ['search',1740,'Search evidence','Exact tested indexes']
  ];
  for(const [id,y,title,subtitle] of artifactDefs){body.push(await card({id,x:1110,y,w:700,h:135,title,subtitle,symbol:'JSON',tone:'azure',compact:true}));}
  body.push(await card({id:'manifest',x:2110,y:830,w:560,h:230,title:'Run manifest',subtitle:'Run IDs, commit, scope, assertions, source and artifact hashes',symbol:'HASH',tone:'navy'}));
  body.push(await card({id:'validator',x:2110,y:1250,w:560,h:210,title:'Offline contract validator',subtitle:'Rejects stale, partial, blocked, tampered, or ambiguous evidence',symbol:'PASS',tone:'green'}));
  body.push(await card({id:'report',x:3000,y:900,w:610,h:260,title:'Reviewed customer findings',subtitle:'Measured, configuration-verified, platform-sourced, and recommended claims remain distinct',symbol:'DOC',tone:'green'}));

  const directPairs=[['canary','agents',675],['deployer','inventory',895],['broad','broad_result',1110],['alpha_probe','alpha_result',1325],['bravo_probe','bravo_result',1545],['search_probe','search',1775]];
  for(const [a,b,y] of directPairs){edges.push(edge({id:`${a}->${b}`,points:[[830,y],[1110,y]],tone:'blue'}));}
  edges.push(edge({id:'broad_result->matrix',points:[[1810,1118],[1900,1118],[1900,1637],[1810,1637]],tone:'neutral'}));
  edges.push(edge({id:'alpha_result->matrix',points:[[1810,1288],[1940,1288],[1940,1637],[1810,1637]],tone:'neutral'}));
  edges.push(edge({id:'bravo_result->matrix',points:[[1810,1458],[1980,1458],[1980,1637],[1810,1637]],tone:'neutral'}));
  const manifestSources=[[1810,677],[1810,917],[1810,1637],[1810,1807]];
  for(let i=0;i<manifestSources.length;i++){edges.push(edge({id:`artifact-${i}->manifest`,points:[[manifestSources[i][0],manifestSources[i][1]],[2050,manifestSources[i][1]],[2050,945],[2110,945]],tone:'neutral'}));}
  edges.push(edge({id:'manifest->validator',points:[[2390,1060],[2390,1250]],label:'Contract checks',lx:2420,ly:1120,lw:230,tone:'green'}));
  edges.push(edge({id:'validator->report',points:[[2670,1355],[2830,1355],[2830,1030],[3000,1030]],label:'Only validated runs',lx:2750,ly:1165,lw:260,tone:'green'}));
  return diagramShell({title:'Test controls and evidence lineage',subtitle:'The evidence path is deliberately fail-closed: attribution and controls become structured artifacts, then a manifest, then reviewed findings.',kicker:'Microsoft Foundry · Assurance method',body:body.join(''),edges:edges.map(e=>e.svg).join(''),labels:edges.map(e=>e.label).join(''),hash});
}

const renderers = {
  'validation-lab-topology': validationLab,
  'measured-authorization-boundary': measuredBoundary,
  'recommended-customer-target-state': targetState,
  'bootstrap-harden-verify-sequence': sequence,
  'test-controls-and-evidence': evidenceFlow
};

await mkdir(outputDir, { recursive: true });

for (const [slug, contract] of Object.entries(lock.contracts)) {
  const sourceBytes = await readFile(join(diagramDir, contract.source));
  const actualHash = sha256(sourceBytes);
  if (actualHash !== contract.sha256) {
    throw new Error(`Approved contract changed: ${contract.source}. Expected ${contract.sha256}, got ${actualHash}.`);
  }
  if (!renderers[slug]) throw new Error(`No renderer for ${slug}.`);
}

const browser = await puppeteer.launch({
  executablePath: browserPath,
  headless: true,
  args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu']
});

const outputs = [];
try {
  for (const [slug, contract] of Object.entries(lock.contracts)) {
    const html = await renderers[slug](contract.sha256);
    const htmlPath = join(outputDir, `.${slug}.html`);
    const outputPath = join(outputDir, `${slug}-azure-architecture.png`);
    await writeFile(htmlPath, html, 'utf8');

    const page = await browser.newPage();
    await page.setViewport({ width: WIDTH, height: HEIGHT, deviceScaleFactor: 1 });
    await page.goto(pathToFileURL(htmlPath).href, { waitUntil: 'networkidle0' });
    await page.evaluate(async () => {
      await document.fonts.ready;
      const images = [...document.images];
      await Promise.all(images.map((image) => image.complete
        ? Promise.resolve()
        : new Promise((resolveImage, rejectImage) => {
            image.addEventListener('load', resolveImage, { once: true });
            image.addEventListener('error', rejectImage, { once: true });
          })));
      if (images.some((image) => image.naturalWidth === 0)) throw new Error('An official icon failed to render.');
    });
    await page.screenshot({ path: outputPath, type: 'png', fullPage: false, omitBackground: false });
    await page.close();

    const image = await loadImage(outputPath);
    if (image.width !== WIDTH || image.height !== HEIGHT) {
      throw new Error(`${basename(outputPath)} is ${image.width}x${image.height}; expected ${WIDTH}x${HEIGHT}.`);
    }
    const canvas = createCanvas(WIDTH, HEIGHT);
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, 0, WIDTH, HEIGHT).data;
    let nonWhiteSamples = 0;
    let samples = 0;
    for (let y = 0; y < HEIGHT; y += 20) {
      for (let x = 0; x < WIDTH; x += 20) {
        const offset = (y * WIDTH + x) * 4;
        samples++;
        if (pixels[offset] < 248 || pixels[offset + 1] < 248 || pixels[offset + 2] < 248) nonWhiteSamples++;
      }
    }
    if (nonWhiteSamples / samples < 0.025) {
      throw new Error(`${basename(outputPath)} appears blank (${nonWhiteSamples}/${samples} non-white samples).`);
    }

    const outputBytes = await readFile(outputPath);
    outputs.push({
      contract: contract.source,
      contract_sha256: contract.sha256,
      output: basename(outputPath),
      output_sha256: sha256(outputBytes),
      bytes: outputBytes.length,
      width: image.width,
      height: image.height,
      sampled_non_white_ratio: Number((nonWhiteSamples / samples).toFixed(4)),
      node_count: contract.nodes.length,
      edge_count: contract.edges.length,
      boundary_count: contract.boundaries.length
    });
    await unlink(htmlPath);
  }
} finally {
  await browser.close();
  for (const name of await readdir(outputDir)) {
    if (name.startsWith('.') && name.endsWith('.html')) {
      await unlink(join(outputDir, name));
    }
  }
}

const iconInventory = [];
for (const name of (await readdir(assetDir)).filter((name) => name.endsWith('.svg')).sort()) {
  const bytes = await readFile(join(assetDir, name));
  iconInventory.push({ file: `assets/azure/${name}`, sha256: sha256(bytes), bytes: bytes.length });
}

const renderManifest = {
  schema_version: '1.0',
  rendered_at_utc: new Date().toISOString(),
  approval_lock: basename(lockPath),
  canvas: { width: WIDTH, height: HEIGHT, background: '#ffffff' },
  renderer: 'scripts/render-approved-diagrams.mjs',
  renderer_sha256: sha256(await readFile(new URL(import.meta.url))),
  official_icon_source: 'https://arch-center.azureedge.net/icons/Azure_Public_Service_Icons_V24.zip',
  icons: iconInventory,
  outputs
};
await writeFile(join(outputDir, 'render-manifest.json'), `${JSON.stringify(renderManifest, null, 2)}\n`, 'utf8');
console.log(`Rendered and pixel-checked ${outputs.length} approved diagrams at ${WIDTH}x${HEIGHT}.`);
