#!/usr/bin/env python3
"""Check published routes, translations, links, metadata and policy preservation."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
import argparse, collections, html, json, re, sys, xml.etree.ElementTree as ET
from render_slowth import SITE, LOCALES, SOURCE, LEGACY, POLICY, POLICY_KEYS, path, url

class Document(HTMLParser):
    def __init__(self, value):
        super().__init__(convert_charrefs=True)
        self.tags=[]; self.ids=set(); self.scripts=[]; self.script=None; self.words=[]
        self.feed(value)
    def handle_starttag(self, tag, attrs):
        a=dict(attrs); self.tags.append((tag,a))
        if 'id' in a:
            assert a['id'] not in self.ids, 'Duplicate id: '+a['id']
            self.ids.add(a['id'])
        if tag=='script': self.script=[a,'']
    def handle_endtag(self, tag):
        if tag=='script': self.scripts.append(self.script); self.script=None
    def handle_data(self, value):
        if self.script is not None:self.script[1]+=value
        else:self.words.append(value)
    def select(self, tag, **attrs):
        return [a for t,a in self.tags if t==tag and all(a.get(k)==v for k,v in attrs.items())]

def plain(s): return html.unescape(re.sub('<[^>]+>','',s))
def links(s):return re.findall(r'<a\b[^>]*href="([^"]+)"',s)
def run():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--app-locales',type=Path);args=ap.parse_args()
    if args.app_locales:
        app=json.loads(args.app_locales.read_text())
        assert set(app['appLanguages'])==set(LOCALES),'App/site locale mismatch'
    docs={};warnings=[]
    for locale in LOCALES:
        messages=json.loads((SITE/'localization/messages'/f'{locale}.json').read_text())
        assert set(messages)==set(SOURCE),f'Incomplete locale: {locale}'
        for key,row in SOURCE.items():
            value=messages[key];assert value.strip(),(locale,key,'empty')
            assert '\n' not in value,(locale,key,'unexpected multiline message')
            assert not re.search(r'ZXQ\s*\d|[\[［]{1,2}\s*\d{4}\s*[\]］]{1,2}|⟦|⟧|\{\{s[a-f0-9]',value,re.I),(locale,key,'placeholder')
            assert sorted(links(value))==sorted(links(row['source'])),(locale,key,'changed link')
            stack=[]
            for raw,end,tag in re.findall(r'(<(/?)([a-z]+)\b[^>]*>)',value):
                if tag=='br':continue
                if end:assert stack and stack.pop()==tag,(locale,key,'unbalanced markup')
                else:stack.append(tag)
            assert not stack,(locale,key,'unclosed markup')
            # Attributes may only come from trusted source markup.
            assert sorted(re.findall(r'<[^/!][^>]*>',value))==sorted(re.findall(r'<[^/!][^>]*>',row['source'])) or not re.search(r'<(?!/?a\b)[^>]+>',value),(locale,key,'changed markup')
            if not locale.startswith('en') and len(plain(row['source']))>80 and plain(value)==plain(row['source']):warnings.append((locale,key,'untranslated paragraph'))
        for page in ['index','support','privacy']:
            p=SITE/path(locale,page);value=p.read_text();d=Document(value);docs[p.resolve()]=d
            assert len(d.select('h1'))==1,(p,'H1 count')
            assert d.select('html')[0]=={'lang':locale,'dir':LOCALES[locale]['direction']},(p,'lang/dir')
            assert d.select('link',rel='canonical')==[{'rel':'canonical','href':url(locale,page)}],(p,'canonical')
            alternatives={a['hreflang']:a['href'] for a in d.select('link',rel='alternate')}
            expected={l:url(l,page) for l in LOCALES};expected['x-default']=url('en',page)
            assert alternatives==expected,(p,'hreflang cluster')
            assert len(d.select('meta',name='description'))==1,(p,'description')
            assert not d.select('meta',name='robots',content='noindex'),(p,'noindex')
            for a,body in d.scripts:
                assert a.get('type')=='application/ld+json',(p,'executable JavaScript')
                schema=json.loads(body)
                assert schema['inLanguage']==locale and schema['url']==url(locale,page),(p,'schema')
            if page=='index':assert len(d.scripts)==1,(p,'missing app schema')
            for a in d.select('img'):
                assert 'alt' in a and a.get('width') and a.get('height'),(p,'image accessibility/dimensions')
            if page=='privacy' and locale in POLICY_KEYS:
                policy=POLICY[POLICY_KEYS[locale]];body=' '.join(d.words)
                for section in policy['sections']:
                    for paragraph in [section['heading']]+section['paragraphs']:
                        assert paragraph in body,(p,'original policy changed',paragraph[:50])
    for p,d in docs.items():
        for tag,a in d.tags:
            targets=[a[k] for k in ['href','src'] if k in a]
            if 'srcset' in a:targets += [s.strip().split()[0] for s in a['srcset'].split(',')]
            for target in targets:
                u=urlsplit(target)
                if u.scheme or u.netloc:continue
                dest=(SITE/u.path.lstrip('/') if u.path.startswith('/') else p.parent/unquote(u.path)).resolve() if u.path else p
                if dest.is_dir():dest=dest/'index.html'
                assert dest.is_file(),(p,target,'missing file')
                if u.fragment and dest.suffix=='.html':
                    other=docs.get(dest) or Document(dest.read_text())
                    assert unquote(u.fragment) in other.ids,(p,target,'missing anchor')
    locations=[n.text for n in ET.parse(SITE/'sitemap.xml').iter('{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
    assert len(locations)==192 and len(set(locations))==192,'Sitemap duplicates/missing pages'
    assert set(locations)=={url(l,p) for l in LOCALES for p in ['index','support','privacy']},'Sitemap mismatch'
    assert not warnings,warnings
    print(f'Passed: {len(LOCALES)} locales, {len(docs)} pages, {len(SOURCE)} messages per locale; links, assets, schema, hreflang, original policies and sitemap.')
if __name__=='__main__':run()
