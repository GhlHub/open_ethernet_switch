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
  let refreshes=0,posts=0;
  let ports={admin:31,physical:17,forwarding:17,advertise:[4,7],applied:[4,7],speed_mbps:[10,0,0,0,1000,0]};
  await page.route('http://kr260.test/**',async route=>{
   const req=route.request(),url=new URL(req.url());
   if(url.pathname==='/api/statistics'){refreshes++;return route.fulfill({json:fixture});}
   if(url.pathname==='/api/ports'){
    if(req.method()==='POST'){
     posts++;const form=new URLSearchParams(req.postData());
     if(req.headers()['x-kr260-request']!=='1')throw Error('Missing change header');
     ports.admin=Number(form.get('mask'));
     ports.advertise=[Number(form.get('adv0')),Number(form.get('adv1'))];
     ports.applied=ports.advertise;
    }
    return route.fulfill({json:ports});
   }
   return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(root,'web/index.html'),'utf8')});
  });
  await page.goto('http://kr260.test/statistics');
  await page.getByRole('heading',{name:'Ethernet ports',exact:true}).waitFor();
  await page.waitForTimeout(2300);
  if(refreshes<3)throw Error('Refresh cadence');
  for(const text of ['18446744073709551615','30.0 °C','31.6 °C','1.800 V','5.000 V','10 Mb/s full duplex'])
   if(!await page.getByText(text,{exact:true}).count())throw Error('Missing exact display: '+text);
  await page.getByRole('link',{name:'Configuration'}).click();
  await page.getByLabel('GEM1 · Right lower advertise 1000 Mb/s',{exact:true}).uncheck();
  await page.getByLabel('GEM1 · Right lower advertise 100 Mb/s',{exact:true}).uncheck();
  await page.getByRole('button',{name:'Apply settings'}).click();
  await page.waitForTimeout(1000);
  if(ports.advertise[0]!==4 || ports.advertise[1]!==1 || posts!==1)throw Error('Advertisement POST');
  await page.getByLabel('GEM1 · Right lower advertise 10 Mb/s',{exact:true}).uncheck();
  await page.getByRole('button',{name:'Apply settings'}).click();
  if(posts!==1 || !(await page.locator('#status').innerText()).includes('at least one'))throw Error('Empty advertisement validation');
  await page.setViewportSize({width:390,height:844});
  if(errors.length)throw Error(errors.join('\n'));
  console.log('PASS: browser navigation, polling, 64-bit values, fixed sensor precision, speeds and advertisement controls');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
