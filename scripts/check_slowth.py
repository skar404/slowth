#!/usr/bin/env python3
"""Check published routes, translations, links, metadata and policy preservation."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
import argparse, collections, html, json, re, sys, xml.etree.ElementTree as ET
from render_slowth import SITE, LOCALES, HREFLANG_LOCALES, SOURCE, LEGACY, POLICY, POLICY_KEYS, path, url, faq_pairs

# ISO 639-1 codes used by this site, independently checked against the locale registry.
SEARCH_LANGUAGES=set('ar be bn ca cs da de el en es fi fr gu ha he hi hr hu hy id it ja ka kk kn ko ky lt ml mr ms nb ne nl or pa pl pt ro ru sk sl sv sw ta te th tr uk ur vi zh'.split())
SEARCH_REGIONS={'EG','AU','CA','GB','MX','BR','PT'}
SEARCH_SCRIPTS={'Arab','Hans','Hant'}

def check_seo(d,locale,page,label):
    assert d.select('link',rel='canonical')==[{'rel':'canonical','href':url(locale,page)}],(label,'canonical')
    tags=d.select('link',rel='alternate')
    alternatives={a['hreflang']:a['href'] for a in tags}
    assert len(tags)==len(alternatives),(label,'duplicate hreflang')
    expected={l:url(l,page) for l in HREFLANG_LOCALES};expected['x-default']=url('en',page)
    assert alternatives==expected,(label,'hreflang cluster')
    for code in alternatives.keys()-{'x-default'}:
        parts=code.split('-')
        assert parts[0] in SEARCH_LANGUAGES and len(parts)<=2,(label,'unsupported language',code)
        assert len(parts)==1 or parts[1] in SEARCH_REGIONS|SEARCH_SCRIPTS,(label,'unsupported region/script',code)
    for meta in d.select('meta'):
        if meta.get('name','').lower() in {'robots','googlebot','bingbot'}:
            tokens=set(re.split(r'[\s,]+',meta.get('content','').lower()))
            assert not tokens & {'noindex','none'},(label,'indexing blocked',meta)
    if page=='index':
        schemas=[(attrs,body) for attrs,body in d.scripts if attrs.get('type')=='application/ld+json']
        parsed=[json.loads(body) for attrs,body in schemas]
        assert len(parsed)==2 and sorted(s.get('@type','') for s in parsed)==['FAQPage','SoftwareApplication'],(label,'missing or duplicate schema')
        schema=next(s for s in parsed if s['@type']=='SoftwareApplication')
        assert schema['@context']=='https://schema.org' and schema['@type']=='SoftwareApplication',(label,'app schema')
        assert schema['name']=='Slowth: Short Video Blocker',(label,'app name')
        assert schema['applicationCategory']=='UtilitiesApplication',(label,'app category')
        assert set(schema['operatingSystem'])=={'iOS','iPadOS','macOS'},(label,'platforms')
        assert schema['downloadUrl']=='https://apps.apple.com/app/id6764140763',(label,'download URL')
        assert schema['isAccessibleForFree'] is True,(label,'free app')
        offer=schema['offers']
        assert offer['@type']=='Offer' and str(offer['price'])=='0' and offer['priceCurrency']=='USD',(label,'free offer')
        assert offer['url']==schema['downloadUrl'],(label,'offer URL')
        assert schema['inLanguage']==locale and schema['url']==url(locale,page),(label,'localized schema')
        faq=next(s for s in parsed if s['@type']=='FAQPage')
        assert faq['@context']=='https://schema.org' and faq['@id']==url(locale,page)+'#faq',(label,'FAQ identity')
        assert faq['inLanguage']==locale and faq['url']==url(locale,page),(label,'localized FAQ')
        pairs=faq_pairs(d.source)
        assert len(pairs)==9 and all(p['question'] and p['answer'] for p in pairs),(label,'visible FAQ')
        expected=[{'@type':'Question','name':p['question'],'acceptedAnswer':{'@type':'Answer','text':p['answer']}} for p in pairs]
        assert faq['mainEntity']==expected,(label,'FAQ differs from visible content')

class Document(HTMLParser):
    def __init__(self, value):
        super().__init__(convert_charrefs=True)
        self.source=value
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
            check_seo(d,locale,page,p)
            assert len(d.select('meta',name='description'))==1,(p,'description')
            for a,body in d.scripts:
                assert a.get('type')=='application/ld+json',(p,'executable JavaScript')
                schema=json.loads(body)
                assert schema['inLanguage']==locale and schema['url']==url(locale,page),(p,'schema')
            if page=='index':assert len(d.scripts)==2,(p,'missing app/FAQ schema')
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
