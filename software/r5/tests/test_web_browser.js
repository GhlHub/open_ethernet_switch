/* Run after make test-web; NODE_PATH must expose a local Playwright install. */
const {chromium}=require('playwright');
const fs=require('fs'),path=require('path');
(async()=>{
 const root=path.resolve(__dirname,'..');
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try {
  const page=await browser.newPage({viewport:{width:1440,height:1000}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const fixture=JSON.parse(fs.readFileSync(path.join(root,'out/test_web.json')));
  fixture.sensors.valid_mask=7;fixture.sensors.temperature_mc=[30000,31550];
  fixture.sensors.voltage_uv=[1800000,850000,1800500,720000,1800000,850000];
  fixture.sensors.som_voltage_uv=5000000;
  let refreshes=0,posts=0,macPosts=0,macGets=0,macPolls=0;
  let mac={busy:false,ready:false,generation:0,age_ms:100,count:1,error:0,pages:16,entries:[]};
  let settings={saved:false,writable:true,admin:31,advertise:[4,7,7,7],sfp:0,dhcp:true,
    ip:'0.0.0.0',netmask:'0.0.0.0',gateway:'0.0.0.0',username:'admin',
    macs:[45,46,47,48,49].map(n=>'00:0a:35:0f:37:'+n)};
  let ports={admin:31,physical:17,forwarding:17,advertise:[4,7,7,7],applied:[4,7,7,7],speed_mbps:[10,0,0,0,1000,0]};
  await page.route('http://kr260.test/**',async route=>{
   const req=route.request(),url=new URL(req.url());
   if(url.pathname.startsWith('/api/mac-table')){
    macGets++;
    if(req.method()==='POST'){
     if(req.headers()['x-kr260-request']!=='1'||req.postData()!=='refresh=1')throw Error('Invalid manual refresh request');
     macPosts++;mac.busy=true;macPolls=0;
     return route.fulfill({status:202,json:mac});
    }
    if(mac.busy && ++macPolls>=2){mac.busy=false;mac.ready=true;mac.generation++;}
    const entries=url.pathname==='/api/mac-table/0'?[[17,'00:0a:35:0f:37:45',6,299]]:[];
    return route.fulfill({json:{...mac,entries}});
   }
   if(url.pathname==='/api/statistics'){refreshes++;return route.fulfill({json:fixture});}
   if(url.pathname==='/api/ports')return route.fulfill({json:ports});
   if(url.pathname==='/api/config'){
    if(req.method()==='POST'){
     if(req.headers()['authorization']!=='Basic YWRtaW46YWRtaW4=')return route.fulfill({status:401,body:'Unauthorized'});
     posts++;const form=new URLSearchParams(req.postData());
     if(req.headers()['x-kr260-request']!=='1')throw Error('Missing change header');
     settings.admin=Number(form.get('mask'));settings.saved=true;
     settings.advertise=[0,1,2,3].map(i=>Number(form.get('adv'+i)));
     settings.sfp=Number(form.get('sfp'));settings.dhcp=form.get('dhcp')==='1';
     for(const k of ['ip','netmask','gateway'])settings[k]=form.get(k);
     ports.admin=settings.admin;ports.advertise=settings.advertise.slice();ports.applied=ports.advertise;
    }
    return route.fulfill({json:settings});
   }
   return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(root,'web/index.html'),'utf8')});
  });
  await page.goto('http://kr260.test/statistics');
  await page.getByRole('heading',{name:'Ethernet ports',exact:true}).waitFor();
  await page.waitForTimeout(2300);
  if(!(await page.locator('#content').innerText()).includes('125 MHz (8 ns/cycle)'))throw Error('Fabric frequency display');
  await page.getByRole('heading',{name:'Statistics availability',exact:true}).waitFor();
  if(!(await page.locator('#content').innerText()).includes('Clock unavailable — stale'))throw Error('Stale bank status missing');
  if(refreshes<3)throw Error('Refresh cadence');
  for(const text of ['18446744073709551615','30.0 °C','31.6 °C','1.800 V','5.000 V','10 Mb/s full duplex'])
   if(!await page.getByText(text,{exact:true}).count())throw Error('Missing exact display: '+text);
  await page.getByRole('link',{name:'Configuration'}).click();
  await page.getByLabel('GEM1 · Right lower advertise 1000 Mb/s',{exact:true}).uncheck();
  await page.getByLabel('GEM1 · Right lower advertise 100 Mb/s',{exact:true}).uncheck();
  await page.locator('#auth-password').fill('admin');
  await page.getByRole('button',{name:'Save settings'}).click();
  await page.waitForTimeout(1000);
  if(ports.advertise[0]!==4 || ports.advertise[1]!==1 || posts!==1)throw Error('Advertisement POST');
  await page.getByLabel('GEM1 · Right lower advertise 10 Mb/s',{exact:true}).uncheck();
  await page.getByRole('button',{name:'Save settings'}).click();
  if(posts!==1 || !(await page.locator('#status').innerText()).includes('at least one'))throw Error('Empty advertisement validation');
  await page.getByLabel('GEM1 · Right lower advertise 10 Mb/s',{exact:true}).check();
  await page.getByLabel('PL0 · Left upper advertise 1000 Mb/s',{exact:true}).uncheck();
  await page.getByLabel('PL0 · Left upper advertise 10 Mb/s',{exact:true}).uncheck();
  await page.getByLabel('PL1 · Left lower advertise 100 Mb/s',{exact:true}).uncheck();
  await page.locator('#ip-mode').selectOption('0');
  await page.locator('#ip').fill('10.0.1.215');
  await page.locator('#netmask').fill('255.255.255.0');
  await page.locator('#gateway').fill('10.0.1.1');
  await page.locator('#sfp').selectOption('2500');
  await page.locator('#auth-password').fill('admin');
  await page.getByRole('button',{name:'Save settings'}).click();
  await page.waitForTimeout(1000);
  if(settings.dhcp || settings.ip!=='10.0.1.215' || settings.sfp!==2500 || posts!==2)throw Error('Persistent IP/SFP POST');
  if(ports.advertise[2]!==2 || ports.advertise[3]!==5)throw Error('PL advertisement POST');
  if(!await page.getByText('00:0a:35:0f:37:45',{exact:true}).count())throw Error('Missing allocated MAC');
  settings.writable=false;await page.getByRole('button',{name:'Reload status'}).click();
  await page.waitForTimeout(250);
  if(!await page.getByRole('button',{name:'Save settings'}).isDisabled())throw Error('Unavailable storage permits save');
  await page.setViewportSize({width:390,height:844});
  await page.getByRole('link',{name:'MAC table',exact:true}).click();
  await page.waitForTimeout(1600);
  if(macPosts!==0 || macGets!==1)throw Error('Opening MAC page triggered scan or polling');
  await page.getByRole('button',{name:'Refresh MAC table',exact:true}).click();
  await page.waitForFunction(()=>!document.querySelector('#mac-refresh').disabled && document.querySelector('#status').textContent.startsWith('MAC snapshot loaded.'));
  if(macPosts!==1 || !await page.getByRole('cell',{name:'00:0a:35:0f:37:45',exact:true}).count())throw Error('Manual snapshot not displayed');
  if(!await page.getByRole('cell',{name:'299',exact:true}).count())throw Error('MAC age missing');
  const gets=macGets;await page.waitForTimeout(1600);
  if(macPosts!==1 || macGets!==gets)throw Error('MAC page automatically refreshes');
  await page.reload();await page.waitForTimeout(1000);
  if(macPosts!==1 || !await page.getByRole('cell',{name:'00:0a:35:0f:37:45',exact:true}).count())throw Error('Cached snapshot not restored');
  if(errors.length)throw Error(errors.join('\n'));
  console.log('PASS: browser navigation, polling, 64-bit values, fixed sensor precision, speeds, persistent port/IP settings, MAC allocation, storage availability and manual-only MAC table refresh');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
