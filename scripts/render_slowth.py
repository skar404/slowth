#!/usr/bin/env python3
"""Render the static Slowth site in every app locale; no runtime translation or JS."""
from pathlib import Path
import argparse,html,json,posixpath,re,hashlib
ROOT=Path(__file__).resolve().parents[1];SITE=ROOT/'website';L10N=SITE/'localization'
LOCALES=json.loads((L10N/'locales.json').read_text());SOURCE=json.loads((L10N/'source.json').read_text())
LEGACY={'en':'privacy.html','ar':'privacy-ar-SA.html','de':'privacy-de-DE.html','es-MX':'privacy-es-MX.html','fr':'privacy-fr-FR.html','hi':'privacy-hi.html','ja':'privacy-ja.html'}
POLICY_KEYS={'en':'en','ar':'ar-SA','de':'de-DE','es-MX':'es-MX','fr':'fr-FR','hi':'hi','ja':'ja'}
BASE='https://slowth.app/'
STYLE_REV=hashlib.sha256((SITE/'style.css').read_bytes()).hexdigest()[:12]
POLICY=json.loads((SITE/'privacy-content.json').read_text())

def path(locale,page):
 if page=='privacy' and locale in LEGACY:return LEGACY[locale]
 if locale=='en':return 'index.html' if page=='index' else page+'.html'
 return locale+'/'+('index.html' if page=='index' else page+'.html')
def url(locale,page):
 name=path(locale,page);return BASE+(name[:-10] if name.endswith('index.html') else name)
def rel(current,target):return posixpath.relpath(target,posixpath.dirname(current) or '.')
def key(s,kind='text'):return 's'+hashlib.sha256((kind+':'+s).encode()).hexdigest()[:12]
def text(messages,s):return html.unescape(messages[key(s)])
def chooser(locale,page,messages):
 current=path(locale,page)
 links='\n'.join('<a href="'+rel(current,path(code,page))+'" lang="'+code+'" hreflang="'+code+'"'+(' aria-current="page"' if code==locale else '')+'><bdi>'+html.escape(info['name'])+'</bdi></a>' for code,info in LOCALES.items())
 return '<details class="language-switcher"><summary aria-label="'+html.escape(text(messages,'Choose a language'),quote=True)+'"><span aria-hidden="true">◎</span> <bdi>'+html.escape(LOCALES[locale]['name'])+'</bdi></summary><nav class="language-menu" aria-label="'+html.escape(text(messages,'Language'),quote=True)+'">'+links+'</nav></details>'

def legacy_messages(locale,messages):
 """Keep the seven existing policy translations verbatim while updating navigation."""
 code=POLICY_KEYS.get(locale)
 if not code:return messages
 original=POLICY['en'];target=POLICY[code];pairs={}
 def walk(a,b):
  if isinstance(a,str):pairs[a]=b
  elif isinstance(a,dict):
   for k in a:walk(a[k],b[k])
  elif isinstance(a,list):
   for x,y in zip(a,b):walk(x,y)
 walk(original,target)
 out=dict(messages)
 for k,row in SOURCE.items():
  raw=html.unescape(row['source'])
  if raw in pairs:out[k]=html.escape(pairs[raw],quote=False) if row['format']=='html' else pairs[raw]
  if raw=='Slowth — Privacy Policy':out[k]='Slowth — '+html.escape(target['title'],quote=False)
 for k,field in [('s7e43887e537a','githubLabel'),('s8427a6df8dbb','cloudflareLabel')]:
  out[k]=SOURCE[k]['source'].replace(original[field],html.escape(target[field],quote=False))
 out['s6d142708016c']=SOURCE['s6d142708016c']['source'].replace('Email:',html.escape(target['emailLabel'],quote=False)+':')
 return out

def render(locale,page,messages):
 current=path(locale,page);prefix='../' if '/' in current else ''
 if page=='privacy':messages=legacy_messages(locale,messages)
 template=(L10N/'templates'/(page+'.html')).read_text()
 if page=='index':
  schema=json.loads((L10N/'schema.json').read_text())
  def tr(v):
   if isinstance(v,str) and re.fullmatch(r'\{\{s[a-f0-9]+\}\}',v):return html.unescape(messages[v[2:-2]])
   if isinstance(v,list):return [tr(x) for x in v]
   if isinstance(v,dict):return {k:tr(x) for k,x in v.items()}
   return v
  schema=tr(schema);schema['url']=url(locale,page);schema['inLanguage']=locale
  template=template.replace('{{SCHEMA}}','<script type="application/ld+json">\n'+json.dumps(schema,ensure_ascii=False,indent=2).replace('</','<\\/')+'\n</script>')
 def substitute(m):
  k=m[1];v=messages[k];return html.escape(v,quote=True) if SOURCE[k]['format']=='text' else v
 result=re.sub(r'\{\{(s[a-f0-9]+)\}\}',substitute,template)
 assert '{{' not in result,(locale,page,'unfilled template')
 result=re.sub(r'<html\b[^>]*>',f'<html lang="{locale}" dir="{LOCALES[locale]["direction"]}">',result,count=1)
 result=result.replace('<body>', '<body class="localized">' if locale!='en' else '<body>')
 # Rewrite only the site's own relative paths; preserve mailto/external links and fragments.
 def href(m):
  value=html.unescape(m[1]);base,sep,anchor=value.partition('#')
  if base in ['index.html','support.html','privacy.html']:
   target={'index.html':'index','support.html':'support','privacy.html':'privacy'}[base]
   value=rel(current,path(locale,target))+(sep+anchor if sep else '')
  elif base.startswith('privacy-') and base.endswith('.html'):
   value=rel(current,base)+(sep+anchor if sep else '')
  elif base in ['style.css','privacy.css','sitemap.xml'] or base.startswith('img/'):value=prefix+value
  if base=='style.css':value+='?v='+STYLE_REV
  return 'href="'+html.escape(value,quote=True)+'"'
 result=re.sub(r'href="([^"]*)"',href,result)
 result=re.sub(r'src="(img/[^"]+)"',lambda m:'src="'+prefix+m[1]+'"',result)
 result=re.sub(r'srcset="([^"]+)"',lambda m:'srcset="'+', '.join(prefix+x.strip() if x.strip().startswith('img/') else x.strip() for x in m[1].split(','))+'"',result)
 result=re.sub(r'<link rel="canonical"[^>]*>',f'<link rel="canonical" href="{url(locale,page)}">',result)
 result=re.sub(r'<meta property="og:url"[^>]*>',f'<meta property="og:url" content="{url(locale,page)}">',result)
 result=re.sub(r'<link rel="alternate"[^>]*>\s*','',result)
 alternates='\n'.join(f'<link rel="alternate" hreflang="{code}" href="{url(code,page)}">' for code in LOCALES)
 alternates+='\n'+f'<link rel="alternate" hreflang="x-default" href="{url("en",page)}">'
 result=result.replace('</head>',alternates+'\n</head>')
 language=chooser(locale,page,messages)
 if page=='privacy':
  result=re.sub(r'<nav class="language-picker".*?</nav>',language,result,flags=re.S)
 else:
  result=result.replace('</nav></header>','</nav>'+language+'</header>',1)
 if locale!='en':
  result=re.sub(r'(<h[12]\b[^>]*>)(.*?)(</h[12]>)',lambda m:m[1]+re.sub(r'<br\s*/?>',' ',m[2])+m[3],result,flags=re.S)
  if page=='index':
   result=result.replace('<span class="copyright">','<p class="screenshot-language-note">'+html.escape(text(messages,'App screenshots are shown in English.'))+'</p><span class="copyright">')
 return result

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');parser.add_argument('--page',choices=['index','support','privacy']);parser.add_argument('--locales',nargs='+');args=parser.parse_args()
 count=0;paths=[]
 for locale in args.locales or LOCALES:
  messages=json.loads((L10N/'messages'/f'{locale}.json').read_text())
  assert messages.keys()==SOURCE.keys(),f'Missing or obsolete translations: {locale}'
  for page in [args.page] if args.page else ['index','support','privacy']:
   content=render(locale,page,messages);name=path(locale,page);target=SITE/name
   if args.check:assert target.read_text()==content,f'Regenerate {name}'
   else:target.parent.mkdir(parents=True,exist_ok=True);target.write_text(content)
   paths.append(name);count+=1
 if not args.page and not args.locales:
  # The five shortcut URLs keep their manifest identity. Ship their UI copy
  # locally; the early app redirect never waits for this optional UI bundle.
  shortcut_keys=json.loads((L10N/'shortcut-messages.json').read_text())
  catalogs={}
  for locale,info in LOCALES.items():
   messages=json.loads((L10N/'messages'/f'{locale}.json').read_text())
   catalogs[locale]={'direction':info['direction'],'messages':{name:messages[k] for name,k in shortcut_keys.items()}}
  content='// Generated by scripts/render_slowth.py. Edit website/localization/messages instead.\n'
  content+='globalThis.slowthShortcutTranslations = '+json.dumps(catalogs,ensure_ascii=False,separators=(',',':')).replace('</','<\\/')+';\n'
  target=SITE/'shortcuts/translations.js'
  if args.check:assert target.read_text()==content,'Regenerate shortcut translations'
  else:target.write_text(content)
  # hreflang clusters are in HTML; sitemap lists canonical URLs without duplicating clusters.
  sitemap='<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'+''.join('  <url><loc>'+url(l,p)+'</loc></url>\n' for l in LOCALES for p in ['index','support','privacy'])+'</urlset>\n'
  target=SITE/'sitemap.xml'
  if args.check:assert target.read_text()==sitemap,'Regenerate sitemap'
  else:target.write_text(sitemap)
 print(('Checked' if args.check else 'Rendered'),count,'pages')
if __name__=='__main__':main()
